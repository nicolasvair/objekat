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

    private var filled: Int { min(peaks.count / 2, resolution) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size)
            }
            .contentShape(Rectangle())
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
        .frame(height: 54)
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

        if let playhead {
            let x = w * CGFloat(min(1, max(0, playhead)))
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: h)) },
                       with: .color(.white.opacity(0.9)), lineWidth: 1)
        }
    }
}

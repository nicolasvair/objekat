import SwiftUI
import AppKit

// MARK: - What the timeline lays over a recording zone, apart from the Canvas
//
// Three small layers, each its own view so that what moves in them invalidates nothing else:
//
//  - `RecordDropGhostOverlay`: the zones about to be born (or the groups about to take an input, or the
//    refusal) under the inputs being dragged. It is the only reader of `recordDropGhosts`, whose value
//    changes with the cursor — read in `TimelineView`'s body, that would rebuild the whole timeline
//    on every pixel (the same reason as `FileDropGhostOverlay`).
//
//  - `ArmedRecordZonesOverlay`: the red frame and the blinking [ o ] of the ARMED zones. The blink is a
//    Core Animation opacity animation on a layer of its own: the render server runs it, so there is no
//    SwiftUI body, no Canvas pass and no Swift code per frame — the cost of the blink is nothing the
//    timeline can feel, and with no zone armed no view exists, so nothing animates at all.
//
//  - `RecordingProgressOverlay`: the take being recorded — a translucent red block per zone, on the lane
//    the take will land on, from the press to the playhead and inside the zone's window (@see
//    RecordProgress), with what the take has drawn so far inside it (notes, or loudness). It reads the
//    playhead through a closure, like `PlayheadLine`: the tick redraws this view and nothing else. Mounted
//    only while recording.

// MARK: The ghost under an input being dragged

struct RecordDropGhostOverlay: View {
    let viewModel: EditViewModel
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let laneStep: Double
    let blockHeight: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(viewModel.recordDropGhosts.enumerated()), id: \.offset) { _, g in
                let refused = g.kind == .refused
                let w = max(refused ? 24 : 3, (g.end - g.start) * pixelsPerSecond)
                let colour: Color = refused ? .red : .accentColor
                RoundedRectangle(cornerRadius: 4)
                    .fill(colour.opacity(g.kind == .assign ? 0.10 : 0.20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(colour.opacity(0.85),
                                          style: StrokeStyle(lineWidth: g.kind == .assign ? 2.5 : 1.5,
                                                             dash: refused ? [4, 3] : []))
                    )
                    .overlay(alignment: .leading) {
                        if w > 46, !g.name.isEmpty {
                            Text(verbatim: g.name)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.primary.opacity(0.75))
                                .padding(.horizontal, 5)
                        }
                    }
                    .frame(width: w, height: blockHeight)
                    .offset(x: g.start * pixelsPerSecond, y: rulerHeight + Double(g.displayLane) * laneStep)
            }
        }
    }
}

// MARK: The take in progress

struct RecordingProgressOverlay: View {
    let viewModel: EditViewModel
    /// A READER, not a value (@see TimelineView.playheadPosition): only this view's body calls it.
    let position: () -> Double
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let laneStep: Double
    let blockHeight: Double

    var body: some View {
        // The picture inside the blocks moves with the recording's tick (30 Hz), not only with the playhead.
        let _ = viewModel.recordingLiveRevision
        let head = position()
        let blocks = viewModel.recordProgressBlocks(head: head)
        ZStack(alignment: .topLeading) {
            ForEach(blocks) { b in
                // The pass being recorded, and — through a loop — the ghost of each finished one under it: the same red,
                // fainter, with a dashed edge (it is not a take yet, it is the place one will take). Inside each, what that
                // pass drew so far: the notes played, or the loudness of the input (@see RecordLivePicture).
                RoundedRectangle(cornerRadius: 3)
                    .fill(RecordZoneIcon.red.opacity(b.current ? 0.30 : 0.15))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(RecordZoneIcon.red.opacity(b.current ? 0.75 : 0.40),
                                      style: StrokeStyle(lineWidth: 1, dash: b.current ? [] : [3, 2])))
                    .overlay {
                        RecordLivePicture(pass: viewModel.recordLivePass(for: b), blockStart: b.start, blockEnd: b.end,
                                          head: head, pixelsPerSecond: pixelsPerSecond)
                    }
                    .frame(width: max(1, (b.end - b.start) * pixelsPerSecond), height: blockHeight)
                    .offset(x: b.start * pixelsPerSecond, y: rulerHeight + Double(b.displayLane) * laneStep)
            }
        }
        .allowsHitTesting(false)
    }
}

/// What a recording block draws inside itself (L11): the notes played on a MIDI input, in red on the block's own pitch
/// range (`MidiNotesDrawing`, the MIDI clips' geometry), or the loudness of an audio input as a symmetric envelope. A
/// SIMPLIFIED picture — one point per tick of the recording, not the file's waveform. An open note runs to the head.
private struct RecordLivePicture: View {
    let pass: RecordLiveCapture.Pass?
    let blockStart: Double
    let blockEnd: Double
    let head: Double
    let pixelsPerSecond: Double

    /// A live note in the shape `MidiNotesDrawing` reads: seconds as "beats" (`secPerBeat` 1) from the block's left edge.
    private struct NoteBox: MidiNoteLike {
        let pitch: Int
        let startBeat: Double
        let lengthBeats: Double
        let velocity: Int
    }

    var body: some View {
        Canvas { ctx, size in
            guard let pass, !pass.isEmpty, size.width > 0, size.height > 0 else { return }
            Self.drawNotes(pass, in: &ctx, size: size, blockStart: blockStart, blockEnd: blockEnd, head: head,
                           pixelsPerSecond: pixelsPerSecond)
            Self.drawPeaks(pass, in: &ctx, size: size, blockStart: blockStart, blockEnd: blockEnd,
                           pixelsPerSecond: pixelsPerSecond)
        }
    }

    private static func drawNotes(_ pass: RecordLiveCapture.Pass, in ctx: inout GraphicsContext, size: CGSize,
                                  blockStart: Double, blockEnd: Double, head: Double, pixelsPerSecond: Double) {
        guard !pass.notes.isEmpty else { return }
        // Cropped to the block: a note that began before it starts at its left edge, one that goes on past it stops at the
        // right edge; one wholly outside is not drawn and does not weigh on the pitch range.
        var shapes: [NoteBox] = []
        for n in pass.notes {
            let end = min(n.end ?? head, blockEnd)
            let start = max(n.start, blockStart)
            guard start <= blockEnd, end >= blockStart else { continue }
            shapes.append(NoteBox(pitch: n.pitch, startBeat: start - blockStart, lengthBeats: max(0, end - start),
                                velocity: n.velocity))
        }
        guard let lo = shapes.map(\.pitch).min(), let hi = shapes.map(\.pitch).max() else { return }
        let layout = MidiNotesDrawing.layout(pitchRange: lo...hi, size: size)
        var path = Path()
        MidiNotesDrawing.forEachNote(notes: shapes, layout: layout, secPerBeat: 1, pixelsPerSecond: pixelsPerSecond,
                                     size: size) { rect, _ in
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: min(2, rect.height / 2), height: min(2, rect.height / 2)))
        }
        ctx.fill(path, with: .color(RecordZoneIcon.red.opacity(0.9)))
    }

    private static func drawPeaks(_ pass: RecordLiveCapture.Pass, in ctx: inout GraphicsContext, size: CGSize,
                                  blockStart: Double, blockEnd: Double, pixelsPerSecond: Double) {
        guard !pass.peaks.isEmpty, blockEnd > blockStart else { return }
        let indices = pass.peakIndices(in: blockStart...blockEnd)
        guard !indices.isEmpty else { return }
        let mid = size.height / 2
        // 10^(dB/20) of the half-height, at least half a point each side so that silence still draws a hairline.
        func half(_ db: Float) -> Double { min(mid, max(0.5, pow(10, Double(db) / 20) * mid)) }
        func x(_ time: Double) -> Double { (time - blockStart) * pixelsPerSecond }
        var path = Path()
        if indices.count == 1 {
            let p = pass.peaks[indices.lowerBound]
            path.addRect(CGRect(x: x(p.time), y: mid - half(p.db), width: 1.5, height: 2 * half(p.db)))
        } else {
            let points = pass.peaks[indices]
            for (i, p) in points.enumerated() {
                let pt = CGPoint(x: x(p.time), y: mid - half(p.db))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            for p in points.reversed() { path.addLine(to: CGPoint(x: x(p.time), y: mid + half(p.db))) }
            path.closeSubpath()
        }
        ctx.fill(path, with: .color(RecordZoneIcon.red.opacity(0.85)))
    }
}

// MARK: The armed zones

struct ArmedRecordZonesOverlay: View {
    let viewModel: EditViewModel
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let laneStep: Double
    let blockHeight: Double

    var body: some View {
        // Nothing armed: no view at all (and `armedRecordZones` answers at once).
        let armed = viewModel.armedRecordZones
        ZStack(alignment: .topLeading) {
            ForEach(armed, id: \.self) { id in
                if let e = viewModel.laneEntry(forID: id) {
                    BlinkingZoneView(cornerRadius: e.item.blockCornerRadius)
                        .frame(width: max(2, e.item.duration * pixelsPerSecond), height: blockHeight)
                        .offset(x: e.absStart * pixelsPerSecond,
                                y: rulerHeight + Double(e.displayLane) * laneStep)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A red frame and a red [ o ], fading in and out together at 2 Hz (a sinusoid, not an on/off), run by
/// Core Animation. "Reduce motion" turns the blink into a steady frame.
private struct BlinkingZoneView: NSViewRepresentable {
    let cornerRadius: Double

    func makeNSView(context: Context) -> BlinkingZoneNSView { BlinkingZoneNSView() }

    func updateNSView(_ view: BlinkingZoneNSView, context: Context) {
        view.cornerRadius = CGFloat(cornerRadius)
    }
}

private final class BlinkingZoneNSView: NSView {
    private let disc = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let dot = CAShapeLayer()
    var cornerRadius: CGFloat = 20 { didSet { if cornerRadius != oldValue { needsLayout = true } } }

    /// The common origin of every blink (@see viewDidMoveToWindow).
    private static let blinkEpoch = CACurrentMediaTime()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let red = NSColor(RecordZoneIcon.red).cgColor
        layer?.borderColor = red
        layer?.borderWidth = 3
        disc.fillColor = NSColor.white.withAlphaComponent(0.55).cgColor
        ring.fillColor = nil
        ring.strokeColor = red
        dot.fillColor = red
        for l in [disc, ring, dot] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { nil }

    /// The overlay never takes a click: the canvas resolves them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(cornerRadius, bounds.height / 2)
        guard let r = RecordZoneIcon.rect(in: bounds) else {
            for l in [disc, ring, dot] { l.isHidden = true }
            return
        }
        let s = RecordZoneIcon.shapes(in: r)
        for l in [disc, ring, dot] { l.isHidden = false }
        disc.path = CGPath(ellipseIn: r, transform: nil)
        ring.path = CGPath(ellipseIn: s.ring, transform: nil)
        ring.lineWidth = s.lineWidth
        dot.path = CGPath(ellipseIn: s.dot, transform: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer else { return }
        layer.removeAnimation(forKey: "blink")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // One half-cycle of 0.25 s, back and forth: 2 Hz. Ease in-out makes the fade a sinusoid.
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.15
        blink.duration = 0.25
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // One origin for every zone (and every redraw of this view): each animation would otherwise start
        // at the instant its own layer is added, and the zones armed one after the other would blink out
        // of step.
        blink.beginTime = layer.convertTime(Self.blinkEpoch, from: nil)
        layer.add(blink, forKey: "blink")
    }
}

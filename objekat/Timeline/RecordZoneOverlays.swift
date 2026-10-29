import SwiftUI
import AppKit

// MARK: - What the timeline lays over a recording zone, apart from the Canvas
//
// Two small layers, each its own view so that what moves in them invalidates nothing else:
//
//  - `RecordDropGhostOverlay`: the zone about to be born (or the group about to take the input, or the
//    refusal) under an input being dragged. It is the only reader of `recordDropGhost`, whose value
//    changes with the cursor — read in `TimelineView`'s body, that would rebuild the whole timeline
//    on every pixel (the same reason as `FileDropGhostOverlay`).
//
//  - `ArmedRecordZonesOverlay`: the red frame and the blinking [ o ] of the ARMED zones. The blink is a
//    Core Animation opacity animation on a layer of its own: the render server runs it, so there is no
//    SwiftUI body, no Canvas pass and no Swift code per frame — the cost of the blink is nothing the
//    timeline can feel, and with no zone armed no view exists, so nothing animates at all.

// MARK: The ghost under an input being dragged

struct RecordDropGhostOverlay: View {
    let viewModel: EditViewModel
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let laneStep: Double
    let blockHeight: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let g = viewModel.recordDropGhost {
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
        layer.add(blink, forKey: "blink")
    }
}

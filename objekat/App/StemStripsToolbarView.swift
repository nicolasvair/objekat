import SwiftUI
import Combine
import AppKit

// MARK: - Stem mixer in the toolbar (INC 1 VU + INC 2 FX)
//
// Replaces the old single 'Main + list of stems' popover. One small strip per bus (Main = the
// general output/master, then each stem): a coloured dot, a short name and a live VU meter.
// Clicking a strip → a popover of the bus's FX chain, which reuses the signal view
// (SynopticBoundView) AS IT IS by pointing it at the stem's UUID (host-aware). A '+' area at
// the end of the bar creates a new stem. The popover also allows renaming the stem (click the
// title) and detaching it from the Main (the 'route to main' checkbox).

struct StemStripsToolbarView: View {
    @Bindable var viewModel: EditViewModel

    @State private var levels: [UUID: Float] = [:]
    @State private var openStemID: UUID? = nil
    // Stems DETACHED from the Main that have gone past 0 dBFS: they stay 'on alert' (a blinking
    // red LED) until acknowledged by clicking the LED. Latched here (it survives the bar being
    // rebuilt).
    @State private var clippedStems: Set<UUID> = []
    // A tick counter for the poll → the blink rate (independent of playback).
    @State private var pollTick: Int = 0
    // @State (and not `let`): the toolbar is rebuilt ~20 times a second by the playhead; a `let`
    // timer would be reset before 0.07 s → it would never fire (a frozen VU).
    @State private var vuPoll = Timer.publish(every: 0.07, on: .main, in: .common).autoconnect()

    // The VU's release coefficient (applied on every 0.07 s tick). ~0.1 → a time constant of
    // ≈ 0.7 s: a 'slow' fall of the order of a second, and an immediate rise. VU/PPM ballistics.
    private let vuReleaseAlpha: Float = 0.1

    // The clip threshold: the engine's level is clamped to 1.0 (= 0 dBFS) → any value at the
    // ceiling means 0 dBFS was passed. We keep a margin under 1.0 for floating-point robustness.
    private let clipThreshold: Float = 0.999

    // Blinking at ~2 Hz: it flips every ~6 ticks (6 × 0.07 s ≈ 0.42 s).
    private var blinkOn: Bool { (pollTick / 6) % 2 == 0 }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(viewModel.stems.enumerated()), id: \.element.id) { idx, stem in
                StemStripButton(
                    stem: stem,
                    isMain: stem.id == viewModel.mainStemID,
                    number: idx < 9 ? idx + 1 : nil,
                    level: levels[stem.id] ?? 0,
                    isOpen: openStemID == stem.id,
                    isClipping: clippedStems.contains(stem.id),
                    blinkOn: blinkOn,
                    onClearClip: { clippedStems.remove(stem.id) }
                ) {
                    openStemID = (openStemID == stem.id) ? nil : stem.id
                }
                .overlay(StemColorMenuOverlay(viewModel: viewModel, stemID: stem.id))
                .popover(isPresented: Binding(
                    get: { openStemID == stem.id },
                    set: { if !$0 && openStemID == stem.id { openStemID = nil } }
                ), arrowEdge: .bottom) {
                    StemFXPopover(viewModel: viewModel, stem: stem,
                                  isMain: stem.id == viewModel.mainStemID,
                                  number: idx < 9 ? idx + 1 : nil)
                }
            }

            // '+': creates a new stem (Main = stem 1 → the first addition = 'Stem 2'). The signal
            // popover does NOT open in its wake: creating a bus is a routing gesture, not an act of
            // chain editing — the strip is there, and one opens it when one needs it (a click on it for
            // the FX or the name).
            Button {
                viewModel.addStem(name: "Stem \(viewModel.stems.count + 1)",
                                  colorIndex: viewModel.stems.count % ObjekatPalette.stems.count)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(L("stem.add.help"))
        }
        .onReceive(vuPoll) { _ in
            pollTick &+= 1
            // VU ballistics (the PPM/VU standard): an almost instant attack — the engine already returns
            // the MAX since the last read (getAndClear) — and a slow release (a falling average over
            // ~1 s). Smoothed in the normalised domain (∝ dBFS) = a linear fall in dB.
            for stem in viewModel.stems {
                let raw  = viewModel.stemLevel(stem.id)
                let prev = levels[stem.id] ?? 0
                levels[stem.id] = raw >= prev ? raw : prev + (raw - prev) * vuReleaseAlpha

                // Clip → latch an alert for any output that really reaches the D/A converter: the MAIN
                // (general output) and DETACHED stems (routeToMain == false, their own physical output).
                // A stem routed to the Main does NOT blink: it is summed in internal 32-bit float, where a
                // momentary overshoot has no consequence — the Main is what will carry the alert if the sum
                // really clips on the way out.
                if raw >= clipThreshold,
                   !stem.muted,
                   stem.id == viewModel.mainStemID || !stem.routeToMain {
                    clippedStems.insert(stem.id)
                }
            }
            // Forgets stems deleted since (which avoids a phantom alert).
            clippedStems.formIntersection(Set(viewModel.stems.map(\.id)))
        }
    }
}

// MARK: - A bus's strip (button)

private struct StemStripButton: View {
    let stem: Stem
    let isMain: Bool
    /// The keyboard shortcut's number (1 = Main, 2 = the 2nd stem…). nil beyond 9.
    let number: Int?
    let level: Float
    let isOpen: Bool
    /// A stem detached from the Main that has clipped (latched) → a blinking red LED until acknowledged.
    var isClipping: Bool = false
    var blinkOn: Bool = true
    var onClearClip: () -> Void = {}
    let action: () -> Void

    // The background is tinted with the stem's colour (replacing the old dot → it saves space and
    // makes the bus's identity readable at a glance). The MAIN has a colour like the others
    // (see ObjekatPalette.stems[0], and recolourable by right-click): its strip has to carry it,
    // otherwise the main bus's identity stayed invisible here while it already tints the stem
    // bands in the timeline.
    private var tint: Color { stem.color }

    /// The horizontal margin of the strip's content. The VU dot therefore touches that edge.
    private static let hPadding: CGFloat = 7
    /// The clip LED deliberately overflows the VU dot: an alert has to be seen.
    private static let clipDotDiameter: CGFloat = 11

    /// The VU dot's legend — the thresholds are those of `StemVuDot.color`. The same for the Main
    /// and for the other buses: it is the same scale, and the same LED to acknowledge.
    private static var vuScaleHelp: String { L("stem.vu.scaleHelp") }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let number {
                    Text(verbatim: "\(number)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(isMain ? L("stem.main.name") : stem.name)
                    .font(.system(size: 11, weight: isMain ? .semibold : .medium))
                    .lineLimit(1)
                    .strikethrough(stem.muted, color: .secondary)
                // A muted bus (the 'N + M' shortcut): the dot is replaced by a 'muted' icon.
                if stem.muted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    StemVuDot(level: level)
                        .help(Self.vuScaleHelp)
                }
            }
            .opacity(stem.muted ? 0.5 : 1)
            .padding(.horizontal, Self.hPadding).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6)
                // Aligned on the background opacity of the timeline blocks (SoundBlockView): at the same
                // level of translucency on a dark background, the colour no longer collapses towards
                // black and stays recognisable as the same hue as in the timeline.
                .fill(tint.opacity(isOpen ? 0.55 : 0.30)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isOpen ? Color.accentColor : tint.opacity(0.55),
                              lineWidth: isOpen ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        // The number is the keyboard shortcut's; it is missing beyond 9, where there is none left.
        .help(L("stem.strip.help", isMain ? L("stem.main.name") : stem.name)
              + (number.map { " \($0)" } ?? "")
              + (stem.muted ? " " + L("stem.strip.mutedSuffix") : ""))
        // A latched clip LED, laid over the VU dot (the strip's right edge).
        // A dedicated button → it catches the acknowledging click without opening the FX popover underneath.
        .overlay(alignment: .trailing) {
            if isClipping && !stem.muted {
                Button(action: onClearClip) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: Self.clipDotDiameter, height: Self.clipDotDiameter)
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                        .opacity(blinkOn ? 1.0 : 0.12)
                        .shadow(color: .red.opacity(blinkOn ? 0.85 : 0), radius: 3)
                }
                .buttonStyle(.plain)
                // The LED is a touch wider than the dot it covers: lining their RIGHT EDGES up on the
                // same margin therefore offset their centres by half the difference, and the red bit
                // into the left of the dot. We line up the CENTRES.
                .padding(.trailing, Self.hPadding - (Self.clipDotDiameter - StemVuDot.diameter) / 2)
                .help(Self.vuScaleHelp)
            }
        }
    }
}

// MARK: - A bus's FX chain popover (the signal view, reused)

private struct StemFXPopover: View {
    @Bindable var viewModel: EditViewModel
    let stem: Stem
    let isMain: Bool
    /// The keyboard shortcut's number (a reminder of the key → stem link). nil beyond 9.
    var number: Int? = nil

    @State private var isEditingName = false
    @State private var editText = ""
    @State private var confirmDelete = false

    // A width fitted to the VERTICAL signal view (the old 540 was sized for the horizontal one).
    private let popoverWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let number {
                    Text(verbatim: "\(number)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if isMain {
                    Text(L("stem.main.subtitle"))
                        .font(.system(.caption, weight: .semibold))
                } else if isEditingName {
                    // Clicking the title → rename the stem.
                    TextField(noLabel, text: $editText)
                        .font(.system(.caption, weight: .semibold))
                        .textFieldStyle(.plain)
                        .onSubmit { viewModel.renameStem(id: stem.id, name: editText); isEditingName = false }
                        .onExitCommand { isEditingName = false }
                } else {
                    Text(stem.name)
                        .font(.system(.caption, weight: .semibold))
                        .onTapGesture { editText = stem.name; isEditingName = true }
                        .help(L("stem.rename.help"))
                }

                Spacer(minLength: 12)

                if !isMain {
                    Toggle(L("stem.routeToMain"), isOn: Binding(
                        get: { stem.routeToMain },
                        set: { viewModel.setStemRouteToMain(stem.id, on: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help(L("stem.routeToMain.help"))

                    // Deleting the stem: the clips assigned to it fall back on the Main.
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("stem.delete.help"))
                    .confirmationDialog(
                        L("stem.delete.confirmTitle", stem.name),
                        isPresented: $confirmDelete, titleVisibility: .visible
                    ) {
                        Button(L("stem.delete.confirmButton"), role: .destructive) {
                            viewModel.removeStem(id: stem.id)   // internal undo push
                        }
                        Button(L("common.cancel"), role: .cancel) {}
                    } message: {
                        Text(L("stem.delete.confirmMessage"))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            // A header taking the stem's colour, the Main included (consistent with its strip's background).
            .background(stem.color.opacity(0.20))

            Divider()

            // The bus (stem = FolderTrack, Main = master) is an FX chain host: we reuse the signal view
            // (vertical) as it is, by pointing it at the stem's UUID.
            SynopticBoundView(viewModel: viewModel, objectID: stem.id, scrolls: true)
                .frame(width: popoverWidth, height: 360)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: popoverWidth)
    }
}

// MARK: - A stem's VU dot (colour = dBFS level)
//
// Replaces the VU bar: a dot whose COLOUR encodes the level (the engine returns a normalised
// level 0..1 ∝ -60..0 dBFS, clamped to 1.0 = 0 dBFS; measured as PEAK on the engine side).
// Steps: grey = no signal (< -40) · blue (-40…-30) · blue→green (-30…-18) · green (-18…-12)
//   green→orange (-12…-6) · orange (-6…0) · red = clip (the level reached 1.0 = 0 dBFS).
// Raising the blue threshold from -60 to -40 keeps the dot from lingering blue as the sound dies away.
// The ballistics (fast attack / ~1 s release) are applied upstream, in the bar's poll.

struct StemVuDot: View {
    let level: Float   // normalised 0..1 (already smoothed)

    /// The dot's diameter. Public because the clip LED sits ON TOP and has to share its centre:
    /// two independent constants, and the circle ends up offset.
    static let diameter: CGFloat = 9

    var body: some View {
        Circle()
            .fill(Self.color(level))
            .frame(width: Self.diameter, height: Self.diameter)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
            // Softens the step between two poll values (0.07 s) → a smooth gradient.
            .animation(.linear(duration: 0.06), value: level)
    }

    static func color(_ level: Float) -> Color {
        // Clip: the engine's level is clamped to 1.0 (= 0 dBFS) → reaching 1.0 = saturation.
        if level >= 0.985 { return .red }

        let dB = Double(level) * 60 - 60   // 0..1 → -60..0 dBFS

        let grey:   (Double, Double, Double) = (0.42, 0.42, 0.44)
        let blue:   (Double, Double, Double) = (0.20, 0.55, 0.95)
        let green:  (Double, Double, Double) = (0.25, 0.80, 0.35)
        let orange: (Double, Double, Double) = (1.00, 0.60, 0.00)

        let rgb: (Double, Double, Double)
        switch dB {
        case ..<(-40):  rgb = grey                                  // no signal / very quiet
        case ..<(-30):  rgb = blue                                  // -40 … -30
        case ..<(-18):  rgb = mix(blue, green,  (dB + 30) / 12)     // -30 … -18
        case ..<(-12):  rgb = green                                 // -18 … -12
        case ..<(-6):   rgb = mix(green, orange, (dB + 12) / 6)     // -12 … -6
        default:        rgb = orange                                // -6 … 0
        }
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    private static func mix(_ a: (Double, Double, Double),
                            _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
        let tt = max(0, min(1, t))
        return (a.0 + (b.0 - a.0) * tt, a.1 + (b.1 - a.1) * tt, a.2 + (b.2 - a.2) * tt)
    }
}

// MARK: - Right-click on a stem strip: a dedicated palette (`ObjekatPalette.stems`,
// 16 hues), distinct from the clips' palette. It changes the bus's own IDENTITY colour
// (its dot plus the clips' stem band); the clips keep their mode (the stem's colour OR a
// custom one) and update themselves through `stemColor(for:)`. A transparent NSView overlay
// laid over the SwiftUI button: it only catches the right click (hitTest returns nil
// otherwise), and the button's left click underneath is untouched.

private struct StemColorMenuOverlay: NSViewRepresentable {
    let viewModel: EditViewModel
    let stemID: UUID

    func makeNSView(context: Context) -> RightClickCaptureView {
        let v = RightClickCaptureView()
        bind(v)
        return v
    }

    func updateNSView(_ nsView: RightClickCaptureView, context: Context) {
        bind(nsView)
    }

    private func bind(_ v: RightClickCaptureView) {
        v.menuProvider = { _ in
            let menu = NSMenu(title: "")
            let current = viewModel.stems.first(where: { $0.id == stemID })?.colorIndex
            let swatchItem = NSMenuItem()
            swatchItem.view = ColorSwatchGridView(currentColorIndex: current,
                                                  palette: ObjekatPalette.stems, columns: 5) { picked in
                Task { @MainActor in viewModel.recolorStem(id: stemID, colorIndex: picked) }
            }
            menu.addItem(swatchItem)
            return menu
        }
    }
}

private final class RightClickCaptureView: NSView {
    var menuProvider: ((RightClickCaptureView) -> NSMenu)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown || event.type == .rightMouseUp else { return nil }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menuProvider else { return }
        NSMenu.popUpContextMenu(menuProvider(self), with: event, for: self)
    }
}

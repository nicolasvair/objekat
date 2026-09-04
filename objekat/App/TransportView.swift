import SwiftUI
import AppKit
import Combine

struct TransportView: View {
    @Binding var isPlaying: Bool
    let playheadPosition: Double
    let totalDuration: Double
    @Bindable var viewModel: EditViewModel
    let onPlay: () -> Void
    let onStop: () -> Void

    private let timeSigOptions: [String] = ["2/4", "3/4", "4/4", "5/4", "6/8", "7/8", "12/8"]

    @State private var bpmText: String = "120"
    @FocusState private var bpmFocused: Bool

    private var remaining: Double { max(0, totalDuration - playheadPosition) }

    private func commitBPM() {
        let normalized = bpmText.replacingOccurrences(of: ",", with: ".")
        if let v = Double(normalized) {
            // applyTempo: clamps, pushes the undo and marks the project as modified.
            viewModel.applyTempo(v)
        }
        bpmText = bpmDisplay(viewModel.tempo)
    }

    private func bpmDisplay(_ bpm: Double) -> String {
        bpm == bpm.rounded() ? "\(Int(bpm))" : String(format: "%.1f", bpm)
    }

    var body: some View {
        HStack(spacing: 12) {
            // The 'audio settings' icon (device + sample rate + buffer) lives on the RIGHT of the
            // toolbar (after the Spacer, further down). The status label 'audio device —
            // 44.1k — 512' shows in the window's TITLE bar instead (see AudioTitleBar).

            Button {
                if isPlaying { onStop() } else { onPlay() }
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.toggleLoopMode()
            } label: {
                Image(systemName: "repeat")
                    .frame(width: 16)
                    .foregroundStyle(viewModel.loopModeEnabled ? Color.orange : Color.primary)
            }
            .buttonStyle(.bordered)
            .help(L("transport.loop.help"))
            .overlay(
                viewModel.loopModeEnabled
                    ? RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.7), lineWidth: 1)
                    : nil
            )

            Text(formatPosition(playheadPosition))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            Text(verbatim: "/ \(formatPosition(totalDuration))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)

            Divider().frame(height: 20)

            // Grid mode + Snap
            Toggle(L("transport.snap"), isOn: $viewModel.snapEnabled)
                .toggleStyle(.button)
                .font(.system(size: 10, weight: .medium))
                .controlSize(.small)
                .help(L("transport.snap.help"))

            Picker(noLabel, selection: $viewModel.gridMode) {
                Text(L("transport.grid.time")).tag(GridMode.time)
                Text(L("transport.grid.bpm")).tag(GridMode.bpm)
            }
            .pickerStyle(.segmented)
            .frame(width: 74)
            .controlSize(.small)
            .help(L("transport.grid.help"))

            // An arrow meaning 'the Time/BPM switch above labels this value' (replacing the old
            // separator plus 'BPM' label): the segmented picker on the left acts as the label.
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                // Brings the arrow closer to its neighbours: the HStack imposes 12 pt on each side,
                // and -6 pt brings each gap back to 6 pt (half).
                .padding(.horizontal, -6)

            // Tempo
            HStack(spacing: 3) {
                TextField(noLabel, text: $bpmText)
                    .frame(width: 26)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 4)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                    .focused($bpmFocused)
                    .onSubmit {
                        commitBPM()
                        bpmFocused = false
                    }
                    .onChange(of: bpmFocused) { _, focused in
                        if !focused { commitBPM() }
                        else { bpmText = bpmDisplay(viewModel.tempo) }
                    }
                    // The field follows the model EVEN when it has focus: at launch, AppKit gives first
                    // responder to the window's first text field (this one), and the old `if !bpmFocused`
                    // guard then froze '120'; on opening a project, losing focus committed that 120 over
                    // the saved tempo.
                    .onChange(of: viewModel.tempo) { _, newTempo in
                        bpmText = bpmDisplay(newTempo)
                    }
                    .onAppear { bpmText = bpmDisplay(viewModel.tempo) }
                    .onKeyPress(.upArrow) {
                        let step = NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0
                        viewModel.applyTempo(viewModel.tempo + step)
                        bpmText = bpmDisplay(viewModel.tempo)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        let step = NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0
                        viewModel.applyTempo(viewModel.tempo - step)
                        bpmText = bpmDisplay(viewModel.tempo)
                        return .handled
                    }
            }

            // Time signature
            Menu {
                ForEach(timeSigOptions, id: \.self) { sig in
                    Button(sig) {
                        let parts = sig.split(separator: "/")
                        if parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]) {
                            viewModel.applyTimeSig(numerator: n, denominator: d)
                        }
                    }
                }
            } label: {
                Text(verbatim: "\(viewModel.timeSigNumerator)/\(viewModel.timeSigDenominator)")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 28)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 36)

            Divider().frame(height: 20)

            ToolPickerButtons(viewModel: viewModel)

            ZoomDragHandles(viewModel: viewModel)

            Divider().frame(height: 20)

            // Stem mixer (INC 1 VU + INC 2 FX): one strip per bus (Main + stems), each with a live
            // VU and an FX chain popover (the signal view). layoutPriority so that the strips keep
            // their natural width (otherwise the greedy Picker squeezes and truncates them).
            StemStripsToolbarView(viewModel: viewModel)
                .layoutPriority(1)

            Spacer()

            // Audio settings (device / sample rate / buffer): an icon at the far RIGHT of the
            // toolbar. The menu is rebuilt every time it opens → devices plugged in while running
            // appear (see AudioSettingsMenu).
            AudioSettingsMenu(viewModel: viewModel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func formatPosition(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let cs = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", m, s, cs)
    }
}

private enum ZoomHandleAxis { case horizontal, vertical }

private struct LockedDragSurface: NSViewRepresentable {
    var axis: ZoomHandleAxis
    var cursor: NSCursor
    var onBegin: () -> Void
    var onDrag: (Double, Double) -> Void
    var onEnd: () -> Void
    var onScroll: ((Double) -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = HandleView()
        v.axis = axis
        v.cursor = cursor
        v.onBegin = onBegin
        v.onDrag = onDrag
        v.onEnd = onEnd
        v.onScroll = onScroll
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? HandleView else { return }
        v.axis = axis
        v.cursor = cursor
        v.onBegin = onBegin
        v.onDrag = onDrag
        v.onEnd = onEnd
        v.onScroll = onScroll
        v.onDoubleClick = onDoubleClick
    }

    final class HandleView: NSView {
        var axis: ZoomHandleAxis = .horizontal
        var cursor: NSCursor = .arrow
        var onBegin: (() -> Void)?
        var onDrag: ((Double, Double) -> Void)?
        var onEnd: (() -> Void)?
        var onScroll: ((Double) -> Void)?
        var onDoubleClick: (() -> Void)?
        private var accDX: Double = 0
        private var accDY: Double = 0
        private var lockOrigin: CGPoint = .zero
        private var dragging = false

        override func resetCursorRects() {
            discardCursorRects()
            addCursorRect(bounds, cursor: cursor)
        }

        override func mouseDown(with event: NSEvent) {
            // A double click = reset (e.g. waveform zoom → 0 dB), not a drag.
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
                return
            }
            onBegin?()
            accDX = 0; accDY = 0
            let global = NSEvent.mouseLocation
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            lockOrigin = CGPoint(x: global.x, y: primaryHeight - global.y)
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(0)
            dragging = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard dragging else { return }
            accDX += Double(event.deltaX)
            accDY += Double(event.deltaY)
            onDrag?(accDX, accDY)
        }

        override func mouseUp(with event: NSEvent) {
            endDrag()
        }

        override func scrollWheel(with event: NSEvent) {
            guard let onScroll else { return }
            let delta = axis == .horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
            guard delta != 0 else { return }
            onScroll(Double(delta))
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endDrag() }
        }

        private func endDrag() {
            guard dragging else { return }
            dragging = false
            CGAssociateMouseAndMouseCursorPosition(1)
            CGWarpMouseCursorPosition(lockOrigin)
            NSCursor.unhide()
            onEnd?()
        }
    }
}

private struct ZoomDragHandles: View {
    @Bindable var viewModel: EditViewModel

    private let minPPS: Double = 1
    private let maxPPS: Double = 200000
    private let minBlockH: Double = 16
    private let maxBlockH: Double = 10000  // the real clamp happens in TimelineView through a dynamic maxBlockHeight
    private let minWaveformDB: Double = 0
    private let maxWaveformDB: Double = 24

    @State private var basePPS: Double = 100
    @State private var baseBlockH: Double = 36
    @State private var baseWaveformDB: Double = 0
    @State private var waveformDBAccum: Double = 0   // scroll accumulation → 1 dB steps

    var body: some View {
        HStack(spacing: 2) {
            handle(icon: "arrow.left.and.right",
                   axis: .horizontal,
                   help: L("transport.zoom.horizontal"),
                   onBegin: {
                       basePPS = viewModel.pixelsPerSecond
                       viewModel.beginHorizontalZoomDrag?()
                   },
                   onDrag: { dx, _ in
                       let mult = exp(dx * 0.006)
                       let target = clamp(basePPS * mult, minPPS, maxPPS)
                       if let f = viewModel.applyHorizontalZoom { f(target) }
                       else { viewModel.pixelsPerSecond = target }
                   },
                   onEnd: { viewModel.endHorizontalZoomDrag?() },
                   onScroll: { delta in
                       let mult = exp(delta * 0.01)
                       let target = clamp(viewModel.pixelsPerSecond * mult, minPPS, maxPPS)
                       if let f = viewModel.applyHorizontalZoom { f(target) }
                       else { viewModel.pixelsPerSecond = target }
                   })

            handle(icon: "arrow.up.and.down",
                   axis: .vertical,
                   help: L("transport.zoom.vertical"),
                   onBegin: {
                       baseBlockH = viewModel.blockHeight
                       viewModel.beginVerticalZoomDrag?()
                   },
                   onDrag: { _, dy in
                       let mult = exp(-dy * 0.008)
                       let target = clamp(baseBlockH * mult, minBlockH, maxBlockH)
                       if let f = viewModel.applyVerticalZoom { f(target) }
                       else { viewModel.blockHeight = target }
                   },
                   onEnd: { viewModel.endVerticalZoomDrag?() },
                   onScroll: { delta in
                       let mult = exp(delta * 0.012)
                       let target = clamp(viewModel.blockHeight * mult, minBlockH, maxBlockH)
                       if let f = viewModel.applyVerticalZoom { f(target) }
                       else { viewModel.blockHeight = target }
                   })

            waveformHandle
        }
    }

    // MARK: The waveform pill — icon plus dB value in a single frame (one control).
    // Drag/scroll = waveform zoom (clamped to whole dB); double click = reset to 0 dB.
    private var waveformHandle: some View {
        ZStack {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .medium))
                Text(verbatim: "\(Int(viewModel.waveformDisplayDB)) dB")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)

            LockedDragSurface(
                axis: .vertical,
                cursor: .resizeUpDown,
                onBegin: { baseWaveformDB = viewModel.waveformDisplayDB },
                onDrag: { _, dy in
                    viewModel.waveformDisplayDB = clamp((baseWaveformDB - dy * 0.15).rounded(),
                                                        minWaveformDB, maxWaveformDB)
                },
                onEnd: {},
                onScroll: { delta in
                    waveformDBAccum -= delta * 0.1
                    let steps = waveformDBAccum.rounded(.towardZero)
                    guard steps != 0 else { return }
                    waveformDBAccum -= steps
                    viewModel.waveformDisplayDB = clamp(viewModel.waveformDisplayDB + steps,
                                                        minWaveformDB, maxWaveformDB)
                },
                onDoubleClick: { viewModel.waveformDisplayDB = 0; waveformDBAccum = 0 }
            )
        }
        .frame(width: 62, height: 18)
        .background(Color.secondary.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .cornerRadius(3)
        .help(L("transport.zoom.waveform"))
    }

    @ViewBuilder
    private func handle(icon: String,
                        axis: ZoomHandleAxis,
                        help: String,
                        onBegin: @escaping () -> Void,
                        onDrag: @escaping (Double, Double) -> Void,
                        onEnd: @escaping () -> Void,
                        onScroll: ((Double) -> Void)? = nil) -> some View {
        ZStack {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            LockedDragSurface(
                axis: axis,
                cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown,
                onBegin: onBegin,
                onDrag: onDrag,
                onEnd: onEnd,
                onScroll: onScroll
            )
        }
        .frame(width: 22, height: 18)
        .background(Color.secondary.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .cornerRadius(3)
        .help(help)
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}

private struct ToolPickerButtons: View {
    @Bindable var viewModel: EditViewModel

    private struct ToolItem {
        let key: String
        /// The label is carried by the button — the tool's name, not its key. Its FIRST LETTER
        /// is the tool's key, and that is why it is bold: the letter reads inside the name, and
        /// the name no longer has to repeat it. An invariant to keep when adding a tool.
        let label: String
        let tool: ActiveTool
        let help: String
    }

    // The bar's order: the four tools that set things, then the cut.
    private let items: [ToolItem] = [
        ToolItem(key: "E", label: "Edit", tool: .toolSelection, help: L("tool.edit.help")),
        ToolItem(key: "V", label: "Vol.", tool: .toolVolume,    help: L("tool.volume.help")),
        ToolItem(key: "P", label: "Pan",  tool: .toolPan,       help: L("tool.pan.help")),
        ToolItem(key: "A", label: "Aux",  tool: .toolAux,       help: L("tool.aux.help")),
        ToolItem(key: "C", label: "Cut",  tool: .toolCut,       help: L("tool.cut.help")),
    ]

    /// The button's label: the initial in bold (= the key), the rest in semibold.
    private static func toolLabel(_ label: String) -> Text {
        Text(String(label.prefix(1))).font(.system(size: 10, weight: .bold))
            + Text(String(label.dropFirst())).font(.system(size: 10, weight: .medium))
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.key) { item in
                let isActive = viewModel.activeTool == item.tool
                Button {
                    viewModel.activeTool = item.tool
                    viewModel.isToolPermanent = true
                    viewModel.heldToolKeyCode = nil
                } label: {
                    Self.toolLabel(item.label)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18, maxHeight: 18)
                        .background(isActive ? Color.accentColor.opacity(0.25) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1)
                        )
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .help(item.help)
            }

            // Solo: NOT an `ActiveTool`, but the same button, in the same place. The 'click =
            // listen' mode lives on `soloKeyHeld`, which the keyboard arms with a HELD 's'; the
            // button, for its part, locks it until the next click on it, for anyone without a free
            // hand. The same entry point as the key: `beginHeldSolo` takes the current selection if
            // there is one, otherwise the first click in the timeline brings the layer into being.
            //
            // Lit on `hasAnySolo` TOO, and not only on its own mode: as soon as a solo filters what
            // is heard — committed with s+⏎, laid on a stem with s+N, or temporary — the button
            // says so, whichever hand set it. It is the 'we are not hearing everything' indicator,
            // and on that count it has to stay lit after an s+⏎.
            //
            // Lit, it turns EVERYTHING off (mode + committed + stems + temporary), like Esc: an
            // indicator that lights up on its own must go out in a single click.
            let soloOn = viewModel.soloKeyHeld || viewModel.hasAnySolo
            Button {
                if soloOn {
                    viewModel.soloKeyHeld = false
                    viewModel.clearAllSolo()
                } else {
                    viewModel.soloKeyHeld = true
                    viewModel.beginHeldSolo()
                }
            } label: {
                Self.toolLabel("Solo")
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18, maxHeight: 18)
                    // Yellow and not the tools' accent: solo is NOT a tool, and it is the same yellow as
                    // its button in the inspector (@see ClipMixZoneView.soloButton).
                    .background(soloOn ? Color.yellow.opacity(0.25) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(soloOn ? Color.yellow : Color.clear, lineWidth: 1)
                    )
                    .cornerRadius(3)
            }
            .buttonStyle(.plain)
            .help(soloOn
                  ? L("transport.solo.active.help")
                  : L("transport.solo.idle.help"))
        }
    }
}

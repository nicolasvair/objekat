import AppKit
import SwiftUI

/// The bar at the bottom of a plugin's editor window, under the Sidechain strip when there is one,
/// on every plugin: the GAIN REDUCTION the plugin publishes (one of its read-only parameters, chosen
/// by its name unless the hand chose, remembered per plugin type — @see EditViewModel+GainReduction),
/// the TRIMS around it moved by one coupled gesture (+n in, −n out), and the GAIN MATCH, which sets
/// the output trim from what was played (@see EditViewModel+Trims). The bar measures only while it
/// is shown; nothing it reads is polled when the window is closed.
struct PluginExpertBar: View {
    let viewModel: EditViewModel
    let plugin: UUID

    static let height: CGFloat = 30
    /// The meter's full scale: past 24 dB of reduction the bar is simply full.
    static let grFullScaleDb: Double = 24

    @State private var candidates: [PluginMeterParameter] = []
    @State private var chosen: PluginMeterParameter?
    @State private var reading: GainReductionValue?
    @State private var playing = false
    @State private var dragAnchor: (input: Float, output: Float)?

    var body: some View {
        let trims = viewModel.pluginTrims(plugin) ?? (0, 0)
        HStack(spacing: 10) {
            if !candidates.isEmpty { gainReduction }
            Spacer(minLength: 4)
            trimControls(trims)
            matchButton
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
        .onAppear {
            candidates = viewModel.meterParameters(of: plugin)
            chosen = viewModel.gainReductionParameter(of: plugin, among: candidates)
            viewModel.setGainMatchMeasuring(pluginID: plugin, true)
        }
        .onDisappear { viewModel.setGainMatchMeasuring(pluginID: plugin, false) }
        .task(id: chosen?.id) {
            // ~30 Hz: the plugin's own text, never a value cached by the model.
            while !Task.isCancelled {
                if let c = chosen { reading = viewModel.gainReductionValue(of: plugin, parameter: c) }
                else { reading = nil }
                playing = viewModel.isTransportRunning
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    // MARK: Gain reduction

    private var gainReduction: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(candidates) { c in
                    Button { choose(c) } label: {
                        if c.id == chosen?.id { Label(c.name, systemImage: "checkmark") } else { Text(verbatim: c.name) }
                    }
                }
                Divider()
                Button { choose(nil) } label: {
                    if chosen == nil { Label(L("expert.gr.none"), systemImage: "checkmark") } else { Text(L("expert.gr.none")) }
                }
            } label: {
                Text(L("expert.gr.short"))
                    .font(.system(size: 10, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("expert.gr.help", chosen?.name ?? L("expert.gr.none")))

            if chosen != nil {
                let db = reading?.decibels ?? 0
                GeometryReader { g in
                    ZStack(alignment: .trailing) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1))
                        // Reduction grows from the RIGHT, as on a console's GR meter.
                        RoundedRectangle(cornerRadius: 2).fill(Color.orange)
                            .frame(width: g.size.width * CGFloat(min(max(db / Self.grFullScaleDb, 0), 1)))
                    }
                }
                .frame(width: 90, height: 6)
                Text(verbatim: reading?.text ?? "—")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 52, alignment: .leading)
            }
        }
    }

    private func choose(_ c: PluginMeterParameter?) {
        viewModel.chooseGainReductionParameter(of: plugin, c)
        chosen = c
    }

    // MARK: Trims

    private func trimControls(_ t: (input: Float, output: Float)) -> some View {
        HStack(spacing: 6) {
            trimLabel(L("expert.trim.in"), t.input)
            // The coupled gesture: a horizontal drag, 0.1 dB per point, on half-dB detents (⌘ = fine).
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 28, height: 18)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(dragAnchor != nil ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if dragAnchor == nil { dragAnchor = t; viewModel.pushUndo() }
                        guard let a = dragAnchor else { return }
                        let raw = Float(v.translation.width) * 0.1
                        let fine = NSEvent.modifierFlags.contains(.command)
                        let d = fine ? (raw * 0.2 * 100).rounded() / 100 : (raw * 2).rounded() / 2
                        let next = EditViewModel.coupledTrims(from: a, delta: d)
                        try? viewModel.setPluginTrims(pluginID: plugin, input: next.input, output: next.output, undo: false)
                    }
                    .onEnded { _ in dragAnchor = nil })
                .onTapGesture(count: 2) {
                    try? viewModel.setPluginTrims(pluginID: plugin, input: 0, output: 0)
                }
                .help(L("expert.trim.drive.help"))
            trimLabel(L("expert.trim.out"), t.output)
        }
    }

    private func trimLabel(_ title: String, _ v: Float) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(verbatim: Self.dbText(v))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(v == 0 ? Color.secondary : Color.primary)
                .frame(minWidth: 40, alignment: .trailing)
        }
    }

    static func dbText(_ v: Float) -> String {
        v == 0 ? "0.0 dB" : String(format: "%+.1f dB", v)
    }

    // MARK: Gain match

    private var matchButton: some View {
        Button {
            do { try viewModel.gainMatch(pluginID: plugin) } catch {
                viewModel.notify(L("expert.match.error.title"),
                                 (error as? EditViewModel.TrimError) == .notPlaying
                                    ? L("expert.match.help.stopped") : L("expert.match.error.signal"))
            }
        } label: {
            Label(L("expert.match.button"), systemImage: "equal.circle")
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!playing)
        .opacity(playing ? 1 : 0.45)
        .help(playing ? L("expert.match.help.playing") : L("expert.match.help.stopped"))
    }
}

extension EditViewModel {

    /// What a native editor gets under its UI: the Sidechain strip (when the plugin has a sidechain
    /// input and sits in an FX chain) above the expert bar (always). Its frame's height is the sum.
    func editorBottomBandView(host: UUID, plugin: UUID) -> NSView {
        let strip = showsSidechainStrip(host: host, plugin: plugin)
        let root = VStack(spacing: 0) {
            if strip { SidechainStripView(viewModel: self, host: host, plugin: plugin) }
            PluginExpertBar(viewModel: self, plugin: plugin)
        }
        let view = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        view.appearance = NSAppearance(named: .darkAqua)
        let h = PluginExpertBar.height + (strip ? SidechainStripView.height : 0)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: h)
        return view
    }
}

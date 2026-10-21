import AppKit
import SwiftUI

/// The bar at the bottom of a plugin's editor window, under the Sidechain strip when there is one,
/// on every plugin: the TRIMS around it moved by one coupled gesture (+n in, −n out), the COMPENSATION
/// after them, and the GAIN MATCH, which sets the compensation (and only it) from what was played (@see
/// EditViewModel+Trims). The bar measures only while it is shown; nothing it reads is polled when the
/// window is closed.
struct PluginExpertBar: View {
    let viewModel: EditViewModel
    let plugin: UUID

    static let height: CGFloat = 30

    @State private var playing = false
    @State private var dragAnchor: (input: Float, output: Float)?
    /// ⇧ (fine) pressed or released mid-drag re-anchors instead of jumping (@see FineAdjust).
    @State private var dragFine = FineAdjust()

    var body: some View {
        let trims = viewModel.pluginTrims(plugin) ?? (0, 0)
        HStack(spacing: 10) {
            Spacer(minLength: 4)
            trimControls(trims)
            compensationLabel(viewModel.pluginCompensation(plugin) ?? 0)
            matchButton
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
        .onAppear {
            viewModel.setGainMatchMeasuring(pluginID: plugin, true)
        }
        .onDisappear { viewModel.setGainMatchMeasuring(pluginID: plugin, false) }
        .task {
            // ~30 Hz: the transport state and the plugin's own bypass, never a value cached by the model.
            while !Task.isCancelled {
                playing = viewModel.isTransportRunning
                // The plugin's own bypass: nothing is measured while it is on (@see OBJPluginProbe.h).
                viewModel.refreshGainMatchBypass(pluginID: plugin)
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    // MARK: Trims

    private func trimControls(_ t: (input: Float, output: Float)) -> some View {
        HStack(spacing: 6) {
            trimLabel(L("expert.trim.in"), t.input)
            // The coupled gesture: a horizontal drag, 0.1 dB per point, on half-dB detents (⇧ = a tenth of the travel, on detents a tenth as wide).
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 28, height: 18)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(dragAnchor != nil ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if dragAnchor == nil { dragAnchor = t; dragFine = FineAdjust(); viewModel.pushUndo() }
                        guard let a = dragAnchor else { return }
                        let fine = NSEvent.modifierFlags.contains(.shift)
                        let travel = dragFine.effective(Double(v.translation.width), fine: fine)
                        let d = Float(FineAdjust.snapped(travel * 0.1, to: 0.5, fine: fine))
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

    /// The gain match's own gain, after the output trim. Double-click: back to 0 (the trims stay).
    private func compensationLabel(_ v: Float) -> some View {
        trimLabel(L("expert.trim.comp"), v)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { try? viewModel.setPluginCompensation(pluginID: plugin, db: 0) }
            .help(L("expert.trim.comp.help"))
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

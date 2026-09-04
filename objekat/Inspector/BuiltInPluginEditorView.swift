import SwiftUI

// MARK: - Built-in parameter editor (the content hosted in BuiltInPluginEditorWindowController)

struct BuiltInPluginEditorView: View {
    var viewModel: EditViewModel
    let plug: ObjectPlugin

    private struct Param: Identifiable {
        let id: Int
        let name: String
        var value: Float
        let min: Float
        let max: Float

        var isFreq: Bool { name.localizedCaseInsensitiveContains("freq") }
        var isGain: Bool { name.localizedCaseInsensitiveContains("gain") }
    }

    @State private var params: [Param] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if params.isEmpty {
                Text(L("plugins.noParameters"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(params) { p in
                            paramRow(p)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 340)
        .onAppear { reload() }
    }

    private func paramRow(_ p: Param) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(shortParamName(p.name))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Spacer()
                Text(formatValue(p))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { Double(params.first(where: { $0.id == p.id })?.value ?? p.value) },
                    set: { newVal in
                        let f = Float(newVal)
                        viewModel.setPluginParam(pluginID: plug.id, index: p.id, value: f)
                        if let i = params.firstIndex(where: { $0.id == p.id }) {
                            params[i].value = f
                        }
                    }
                ),
                in: Double(p.min)...Double(p.max)
            )
        }
        // A plain CLICK on the row (its name, its value, or the slider without moving it) names that
        // parameter as its object's 'future automation'. Without it one would have to knock the
        // parameter off its value to be able to automate it — which a built-in editor has no reason to impose.
        .contentShape(Rectangle())
        .onTapGesture { touch(p) }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in touch(p) })
    }

    /// Reports the parameter being touched, without changing anything. Idempotent and free once the
    /// parameter is at the head of the touch memory (@see EditViewModel.recordAutomationTouch).
    private func touch(_ p: Param) {
        guard let pid = viewModel.pluginParamInfos(plug.id)
                                 .first(where: { $0.value.index == p.id })?.key else { return }
        viewModel.recordPluginParamTouch(pluginKey: plug.id, paramID: pid)
    }

    private func shortParamName(_ name: String) -> String {
        if name.localizedCaseInsensitiveContains("freq") { return "Freq" }
        if name.localizedCaseInsensitiveContains("gain") { return "Gain" }
        if name.localizedCaseInsensitiveContains(" Q")   { return "Q" }
        return name
    }

    private func formatValue(_ p: Param) -> String {
        if p.isFreq {
            return p.value >= 1000
                ? String(format: "%.1f kHz", p.value / 1000)
                : String(format: "%.0f Hz", p.value)
        }
        if p.isGain { return String(format: "%+.1f dB", p.value) }
        return String(format: "%.2f", p.value)
    }

    private func reload() {
        params = viewModel.getPluginParams(pluginID: plug.id).map {
            Param(id: $0.index, name: $0.name, value: $0.value,
                  min: $0.min, max: $0.max)
        }
    }
}

import Foundation

// MARK: - The gain reduction a plugin publishes, for its editor's bar

/// One read-only parameter a plugin exposes (@see OBJEngineCore `pluginMeterParameters:`).
struct PluginMeterParameter: Equatable, Identifiable {
    let index: Int
    let id: String
    let name: String
}

/// What the bar reads now: the plugin's text and, when it holds a number, its magnitude in dB.
struct GainReductionValue: Equatable {
    let text: String
    let decibels: Double?
}

extension EditViewModel {

    /// The plugin's read-only parameters ([] for a built-in, an instance still loading, a plugin that
    /// declares none). Asked when the bar appears, never per frame.
    func meterParameters(of pluginID: UUID) -> [PluginMeterParameter] {
        (engine?.pluginMeterParameters(pluginID.uuidString) ?? []).compactMap { d in
            guard let i = d["index"] as? Int, let id = d["id"] as? String, let n = d["name"] as? String
            else { return nil }
            return PluginMeterParameter(index: i, id: id, name: n)
        }
    }

    /// The parameter the bar reads: the one remembered for this plugin TYPE if it still exists, else
    /// the one whose name says gain reduction; nil = nothing shown (or the hand chose nothing).
    func gainReductionParameter(of pluginID: UUID, among candidates: [PluginMeterParameter]) -> PluginMeterParameter? {
        guard let t = presetTarget(pluginID) else { return nil }
        if let chosen = PluginMeterMemory.chosen(format: t.plugin.formatName, identifier: t.plugin.identifier) {
            if chosen == PluginMeterMemory.none { return nil }
            if let p = candidates.first(where: { $0.id == chosen }) { return p }
        }
        return GainReductionReading.defaultIndex(names: candidates.map(\.name)).map { candidates[$0] }
    }

    /// The hand's choice for this plugin TYPE (nil = show nothing).
    func chooseGainReductionParameter(of pluginID: UUID, _ p: PluginMeterParameter?) {
        guard let t = presetTarget(pluginID) else { return }
        PluginMeterMemory.choose(p?.id ?? PluginMeterMemory.none,
                                 format: t.plugin.formatName, identifier: t.plugin.identifier)
    }

    func gainReductionValue(of pluginID: UUID, parameter: PluginMeterParameter) -> GainReductionValue? {
        guard let r = engine?.pluginParameterReading(pluginID.uuidString, index: Int32(parameter.index)),
              let text = r["text"] as? String else { return nil }
        let label = (r["label"] as? String) ?? ""
        let shown = label.isEmpty || text.contains(label) ? text : text + " " + label
        return GainReductionValue(text: shown, decibels: GainReductionReading.decibels(fromText: text))
    }
}

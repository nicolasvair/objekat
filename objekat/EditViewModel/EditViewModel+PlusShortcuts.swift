import Foundation

// MARK: - The plugins the "+" directions are bound to, against the catalogue (@see PlusShortcutMap)

extension PlusPluginRef {
    /// The reference a direction keeps of a catalogue entry.
    init(_ plugin: AvailablePlugin) {
        self.init(format: plugin.formatName, identifier: plugin.identifier,
                  name: plugin.name, manufacturer: plugin.manufacturer)
    }

    /// Whether `plugin` is this one (the same `format|identifier`, @see key).
    func matches(_ plugin: AvailablePlugin) -> Bool { PlusPluginRef(plugin) == self }
}

extension AvailablePlugin {
    /// Whether a "+" direction can be bound to it: a plain effect. An instrument needs MIDI at its input,
    /// which no FX chain gives it (the browser leaves them out of every chain for the same reason). A VST3
    /// flagged as a possible ARA source stays bindable: the flag is a pre-filter with false positives (RX,
    /// Ozone…), and such a plugin is listed as an ordinary effect by the browser too.
    var canBindToPlusDirection: Bool { !isInstrument }
}

extension EditViewModel {
    /// The catalogue entry `ref` names, if it is installed AND can be inserted in a chain; nil otherwise —
    /// which is what makes its direction "unavailable" (greyed, and doing nothing). The catalogue is the one
    /// the browser lists (an instance that failed to load is taken out of it there too, @see synopticInsert).
    func availablePlugin(for ref: PlusPluginRef) -> AvailablePlugin? {
        availablePlugins.first { ref.matches($0) && $0.canBindToPlusDirection }
    }
}

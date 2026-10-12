import Foundation

// MARK: - The gain stage (model side, pure)
//
// A gain stage is an ORDINARY plugin leaf of a chain: `formatName "TracktionInternal"`, identifier
// `objGainStage` (the "gain" face) or `objGainPanMute` (the "gain + pan + mute" face). The engine
// class is one and the same for both faces, with ONE parameter list — index 0 gain (dB), 1 pan,
// 2 mute — so that linked instances (paired by INDEX) can never pair a gain with a pan
// (@see OBJGainStagePlugin.h). Being a leaf, it is copied, cut, linked, put in an FX link, carried
// to a send's mini-chain, consolidated, baked and automated by every walker that already exists.
//
// Two things set it apart from any other plugin, and both are read from HERE: it has no bypass of
// its own (a bin's common on/off still takes it with the rest of the bin), and it never opens an
// editor (its controls are its card's). It is also what the old chain trims and an FX link's output
// section became at load (@see LegacyGainMigration).

/// The two faces of a gain stage.
nonisolated enum GainStageFace: String, Codable, CaseIterable, Sendable {
    /// The gain alone.
    case gain
    /// Gain + pan + mute — the old FX link output section, as a card.
    case gainPanMute = "gain_pan_mute"

    /// The engine type name (`ObjectPlugin.identifier`).
    var identifier: String {
        switch self {
        case .gain:        return "objGainStage"
        case .gainPanMute: return "objGainPanMute"
        }
    }

    /// The plugin's name in the model (data, like every built-in's name: not localised).
    var pluginName: String {
        switch self {
        case .gain:        return "Gain"
        case .gainPanMute: return "Gain · Pan"
        }
    }

    init?(identifier: String) {
        guard let face = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = face
    }
}

/// What a gain stage is set to.
nonisolated struct GainStageValues: Equatable, Sendable {
    var gainDb: Float = 0
    var pan: Float = 0
    var muted: Bool = false

    static let neutral = GainStageValues()

    /// The stage's ENGINE range of the gain, in dB, for the hand as for the engine (user decision of
    /// 12 October 2026: ±24 dB everywhere). Every legacy trim fits exactly.
    static let gainRange: ClosedRange<Float> = -24...24
    static let panRange: ClosedRange<Float> = -1...1

    /// The parameter indices of the engine class (one list for both faces).
    static let gainIndex = 0
    static let panIndex  = 1
    static let muteIndex = 2

    /// The parameter ids the engine reports (`ParamRef.plugin(…, paramID:)`).
    static let gainParamID = "gain"
    static let panParamID  = "pan"
    static let muteParamID = "mute"

    /// A gain in dB as an automation value of the model (plugin parameters are stored 0…1 and
    /// denormalised LINEARLY over the engine's range — @see EditViewModel.denormalizedPluginValue).
    static func normalizedGain(_ dB: Float) -> Float {
        (min(max(dB, gainRange.lowerBound), gainRange.upperBound) - gainRange.lowerBound)
            / (gainRange.upperBound - gainRange.lowerBound)
    }

    /// The same values, every field within its range.
    var clamped: GainStageValues {
        GainStageValues(gainDb: min(max(gainDb, Self.gainRange.lowerBound), Self.gainRange.upperBound),
                        pan: min(max(pan, Self.panRange.lowerBound), Self.panRange.upperBound),
                        muted: muted)
    }
}

extension ObjectPlugin {

    /// The face of this entry when it is a gain stage, nil otherwise.
    var gainStageFace: GainStageFace? {
        guard formatName == "TracktionInternal", !isContainer else { return nil }
        return GainStageFace(identifier: identifier)
    }

    /// True if this entry is a gain stage (either face).
    var isGainStage: Bool { gainStageFace != nil }

    /// A NEW gain stage leaf: a fresh id, the face's name, and a state carrying `values` — the engine
    /// builds the instance from that state, so the stage is born at its value (no ramp, no later
    /// write). `id` is for the tests and the migration's determinism checks only; callers leave it.
    static func makeGainStage(face: GainStageFace, values: GainStageValues = .neutral,
                              id: UUID = UUID(), linkGroupID: UUID? = nil) -> ObjectPlugin {
        ObjectPlugin(id: id, name: face.pluginName, manufacturer: "OBJEKAT",
                     identifier: face.identifier, formatName: "TracktionInternal",
                     isEnabled: true,
                     stateXML: gainStageStateXML(face: face, values: values),
                     linkGroupID: linkGroupID)
    }

    /// The engine state of a stage: the plugin tree with the three cached values the class reads.
    static func gainStageStateXML(face: GainStageFace, values: GainStageValues) -> String {
        let v = values.clamped
        return "<PLUGIN type=\"\(face.identifier)\" gainDb=\"\(Self.xmlNumber(v.gainDb))\" "
             + "pan=\"\(Self.xmlNumber(v.pan))\" muted=\"\(v.muted ? 1 : 0)\"/>"
    }

    /// The values a stage's `stateXML` holds (the engine's flushed tree or `gainStageStateXML`'s),
    /// read from the ROOT element only. Absent attributes are neutral. nil when not a stage.
    var gainStageStoredValues: GainStageValues? {
        guard isGainStage else { return nil }
        guard let xml = stateXML, let open = xml.range(of: "<PLUGIN") else { return .neutral }
        let rest = xml[open.upperBound...]
        let tag = rest.prefix { $0 != ">" }
        func attr(_ name: String) -> String? {
            guard let r = tag.range(of: " \(name)=\"") else { return nil }
            let after = tag[r.upperBound...]
            return String(after.prefix { $0 != "\"" })
        }
        var out = GainStageValues.neutral
        if let g = attr("gainDb").flatMap(Float.init) { out.gainDb = g }
        if let p = attr("pan").flatMap(Float.init) { out.pan = p }
        if let m = attr("muted") { out.muted = (m == "1" || m.lowercased() == "true") }
        return out
    }

    private static func xmlNumber(_ f: Float) -> String {
        // Shortest exact text: `-6`, `0.25`, `-4.5` (never `-6.000000`).
        f == f.rounded() ? String(Int(f)) : String(f)
    }
}

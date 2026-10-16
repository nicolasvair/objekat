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

    /// The same stage whose STORED state carries `values` (clamped): the three attributes of the root
    /// `<PLUGIN …>` element are rewritten in place, or added when absent, and everything else the
    /// engine's flushed tree holds is left as it is. A stage with no state (or none `<PLUGIN` opens)
    /// gets `gainStageStateXML`'s. Not a stage: returned unchanged.
    ///
    /// This is the model's MIRROR of the live instance (@see EditViewModel.mirrorGainStageValues): the
    /// value lives in the engine, which nothing observes, and the drawn waveform reads the model.
    func withGainStageStoredValues(_ values: GainStageValues) -> ObjectPlugin {
        guard let face = gainStageFace else { return self }
        let v = values.clamped
        var out = self
        guard let xml = stateXML, let open = xml.range(of: "<PLUGIN"),
              let close = xml[open.upperBound...].firstIndex(of: ">") else {
            out.stateXML = Self.gainStageStateXML(face: face, values: v)
            return out
        }
        var tag = String(xml[open.upperBound..<close])
        func set(_ name: String, _ value: String) {
            if let r = tag.range(of: " \(name)=\""),
               let end = tag[r.upperBound...].firstIndex(of: "\"") {
                tag.replaceSubrange(r.upperBound..<end, with: value)
            } else {
                // Before the slash of a self-closing tag, if it has one.
                let at = tag.hasSuffix("/") ? tag.index(before: tag.endIndex) : tag.endIndex
                tag.insert(contentsOf: " \(name)=\"\(value)\"", at: at)
            }
        }
        set("gainDb", Self.xmlNumber(v.gainDb))
        set("pan", Self.xmlNumber(v.pan))
        set("muted", v.muted ? "1" : "0")
        out.stateXML = String(xml[..<open.upperBound]) + tag + String(xml[close...])
        return out
    }

    private static func xmlNumber(_ f: Float) -> String {
        // Shortest exact text: `-6`, `0.25`, `-4.5` (never `-6.000000`).
        f == f.rounded() ? String(Int(f)) : String(f)
    }
}

// MARK: - The gain stages in the drawn waveform (pure)
//
// The drawn waveform follows the object's fader (`volume`) AND the gain of its own gain stages: a
// stage is dB in a straight line, so it moves the waveform exactly as far as it moves the sound —
// what the two chain trims did until format 24 (they became stages, @see LegacyGainMigration).
//
// What counts: the stages of the object's MAIN serial chain — its root series, and the series of an
// FX link's block sitting in it (a bin is serial), unless that bin is switched off (the bin's common
// on/off: the registry's while attached, `local` while detached). A stage's own `isEnabled` is
// honoured although a stage has no bypass of its own. What does NOT count: a parallel block's
// branches (a branch is one voice of a sum, not the object's level), a send's mini-chain (not the
// object's output), the stem / Main chains (not the object's), any third-party or other built-in
// plugin (what it does to the level cannot be known without rendering), and a stage's pan and mute
// (not a gain: an object's own mute greys its block, it does not flatten its waveform).
//
// The value is the model's STORED one (`gainStageStoredValues`), kept in step with the instance by
// every write of the hand or the API (@see EditViewModel.mirrorGainStageValues). An automated stage is
// drawn at that static value, as an automated fader is drawn at `volume`: the drawing ignores curves.
enum GainStageDisplay {

    /// The sum (dB) of the gains of the stages of `plugins`' main serial chain. `offBins`: the ids of
    /// the ATTACHED FX links whose common on/off is off (@see EditViewModel.offFXLinkIDs).
    static func serialStagesGainDb(_ plugins: [ObjectPlugin], offBins: Set<UUID>) -> Float {
        var sum: Float = 0
        for p in plugins {
            if let fb = p.fxBlock {
                let on = fb.isDetached ? (fb.local?.isEnabled ?? true) : !offBins.contains(fb.linkID)
                if on { sum += serialStagesGainDb(fb.plugins, offBins: offBins) }
                continue
            }
            // A parallel block (`rack`) or a send's place on the trunk: not the object's serial level.
            guard !p.isContainer, p.isEnabled, let v = p.gainStageStoredValues else { continue }
            sum += v.clamped.gainDb
        }
        return sum
    }

    /// The gain (dB) the drawn waveform follows: the fader plus the serial stages. A fader at -96 dB
    /// (silence) stays silence whatever the stages add — a muted-by-fader object does not come back on
    /// the screen because of a +12 (the rule the trims followed until format 24).
    static func effectiveDisplayGainDb(volume: Float, plugins: [ObjectPlugin], offBins: Set<UUID>) -> Float {
        if volume <= -96 { return volume }
        return volume + serialStagesGainDb(plugins, offBins: offBins)
    }
}

extension SoundObject {
    /// The gain the DRAWN waveform follows: the fader plus the gain stages of its main serial chain
    /// (@see GainStageDisplay). A clip's own drawing, a group's composite (each child's contribution, then
    /// the group's own, a product) and an infinite bus's band all read it.
    ///
    /// A DISPLAY approximation, on purpose. What is heard is `volume` then the chain, and the other
    /// plugins in between (a compressor, an EQ) can change the level by any amount the drawing cannot
    /// know without rendering; a stage is dB in a straight line, so it is counted exactly.
    func waveformDisplayGainDb(offBins: Set<UUID>) -> Float {
        GainStageDisplay.effectiveDisplayGainDb(volume: volume, plugins: plugins, offBins: offBins)
    }
}

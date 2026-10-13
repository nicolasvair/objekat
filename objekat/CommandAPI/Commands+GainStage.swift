import Foundation

// MARK: - Gain stages
//
// The gain stage is a plugin leaf of a chain (@see GainStage.swift): `plugin.list`, `plugin.remove`,
// `plugin.move`, `plugin.set_param` & co. address it like any other. These two commands are the
// ones it needs of its own: laying one (the "+" drag's door) and reading it as a person reads it.
extension CommandRegistry {

    func registerGainStageCommands() {

        register("plugin.add_gain_stage",
                 summary: """
                 Lays a GAIN STAGE into a chain — the "+" drag's gesture: `face` "gain" (a gain alone) or \
                 "gain_pan_mute" (gain + pan + mute). `series`: "root" (default), `{voice: {block, index}}` \
                 (a parallel block's branch), `{block}` (an FX link's block: in an ATTACHED block the stage \
                 joins the bin's definition and every member gets a linked instance) or `{send: aux}` (the \
                 mini-chain of `host`'s send towards `aux`). `index`: the place in that series (the view's \
                 index: send markers do not count at the root; default the end). Born at `gain_db` \
                 (±24 dB), `pan` (-1…1), `muted`. No bypass, no editor. One undo point. Refused: \
                 `chainFull` (invalid_state, `details.reason`), an unknown series (not_found), a value out \
                 of range (bad_params). Answers `{host, plugin}` (+ `definition` in an attached bin).
                 """,
                 params: [ParamSpec("host", "uuid", "Object or stem carrying the chain (the SENDER for `{send}`)."),
                          ParamSpec("face", "string", "\"gain\" or \"gain_pan_mute\"."),
                          ParamSpec("series", "string|object", required: false,
                                    "\"root\" | {voice:{block,index}} | {block} | {send: aux}."),
                          ParamSpec("index", "int", required: false, "Place in the series (default: the end)."),
                          ParamSpec("gain_db", "number", required: false, "Starting gain, -24…24 dB (default 0)."),
                          ParamSpec("pan", "number", required: false, "Starting pan, -1…1 (default 0)."),
                          ParamSpec("muted", "bool", required: false, "Starting mute (default false).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            _ = try CommandContext.shared.requireEngine()
            var host = try p.uuid("host")
            guard let face = GainStageFace(rawValue: try p.string("face")) else {
                throw CommandError(code: .bad_params, message: "face must be \"gain\" or \"gain_pan_mute\"")
            }
            var values = GainStageValues.neutral
            if let g = try p.optionalDouble("gain_db") {
                guard GainStageValues.gainRange.contains(Float(g)) else {
                    throw CommandError(code: .bad_params, message: "gain_db must lie within -24…24 dB",
                                       details: .object(["reason": .string("gain_out_of_range")]))
                }
                values.gainDb = Float(g)
            }
            if let pan = try p.optionalDouble("pan") {
                guard GainStageValues.panRange.contains(Float(pan)) else {
                    throw CommandError(code: .bad_params, message: "pan must lie within -1…1",
                                       details: .object(["reason": .string("pan_out_of_range")]))
                }
                values.pan = Float(pan)
            }
            values.muted = try p.bool("muted", or: false)

            let series = try Self.gainStageSeries(p.raw["series"], host: &host, in: vm)
            guard vm.chainPlugins(host) != nil else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            switch vm.insertGainStage(host: host, series: series, index: try p.optionalInt("index"),
                                      face: face, values: values) {
            case .failure(let why):
                switch why {
                case .unknownHost:
                    throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
                case .unknownSeries:
                    throw CommandError(code: .not_found, message: "unknown series in this chain",
                                       details: .object(["reason": .string(why.rawValue)]))
                case .chainFull:
                    throw CommandError(code: .invalid_state, message: "the chain is full",
                                       details: .object(["reason": .string(why.rawValue)]))
                }
            case .success(let id):
                guard let placed = vm.chainEntry(ofPlugin: id)?.plugin else {
                    throw CommandError(code: .engine_error, message: "the stage vanished after being laid")
                }
                var out: [String: JSONValue] = ["host": .string(host.uuidString),
                                                "plugin": CommandAdapters.pluginPayload(placed)]
                if let def = placed.linkGroupID, vm.fxLinks.contains(where: { $0.plugins.contains { $0.id == def } }) {
                    out["definition"] = .string(def.uuidString)
                }
                return .object(out)
            }
        }

        register("plugin.gain_stage",
                 summary: """
                 A gain stage as a person reads it: `{plugin, host, face, gain_db, pan, muted}`, read from the \
                 live instance (the model's stored state before it is compiled). Writes go through \
                 `plugin.set_param` (index 0 gain dB, 1 pan, 2 mute 0/1). `invalid_state` when the plugin \
                 is not a gain stage.
                 """,
                 params: [ParamSpec("plugin", "uuid", "The stage.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            guard let entry = vm.chainEntry(ofPlugin: id) else {
                throw CommandError(code: .not_found, message: "unknown plugin: \(id.uuidString)")
            }
            guard let face = entry.plugin.gainStageFace, let v = vm.gainStageValues(id) else {
                throw CommandError(code: .invalid_state, message: "plugin \(id.uuidString) is not a gain stage",
                                   details: .object(["reason": .string("not_a_gain_stage")]))
            }
            return .object(["plugin": .string(id.uuidString),
                            "host": .string(entry.host.uuidString),
                            "face": .string(face.rawValue),
                            "gain_db": .number(Double(v.gainDb)),
                            "pan": .number(Double(v.pan)),
                            "muted": .bool(v.muted)])
        }
    }

    /// `series` of `plugin.add_gain_stage` → a series of the chain. `{send: aux}` re-aims `host` at
    /// the mini-chain of its send towards `aux` (whose root it then is).
    @MainActor
    private static func gainStageSeries(_ raw: JSONValue?, host: inout UUID,
                                        in vm: EditViewModel) throws -> SeriesLocation {
        guard let raw, raw != .null else { return .root }
        if raw.stringValue == "root" { return .root }
        guard let o = raw.objectValue else {
            throw CommandError(code: .bad_params,
                               message: "series must be \"root\", {voice:{block,index}}, {block} or {send}")
        }
        func uuid(_ v: JSONValue?, _ what: String) throws -> UUID {
            guard let s = v?.stringValue, let u = UUID(uuidString: s) else {
                throw CommandError(code: .bad_params, message: "series.\(what): a uuid expected")
            }
            return u
        }
        if let voice = o["voice"]?.objectValue {
            guard let i = voice["index"]?.intValue else {
                throw CommandError(code: .bad_params, message: "series.voice.index: an int expected")
            }
            return .voice(blockID: try uuid(voice["block"], "voice.block"), voiceIndex: i)
        }
        // The shape `plugin.drop_at` already takes: {voice: <block id>, index: <branch>}.
        if o["voice"]?.stringValue != nil {
            guard let i = o["index"]?.intValue else {
                throw CommandError(code: .bad_params, message: "series.index: an int expected")
            }
            return .voice(blockID: try uuid(o["voice"], "voice"), voiceIndex: i)
        }
        if o["block"] != nil { return .block(blockID: try uuid(o["block"], "block")) }
        if o["send"] != nil {
            let aux = try uuid(o["send"], "send")
            guard vm.sendEntry(from: host, to: aux) != nil else {
                throw CommandError(code: .not_found, message: "no send from \(host.uuidString) to \(aux.uuidString)")
            }
            host = SendChain.hostID(sender: host, aux: aux)
            return .root
        }
        throw CommandError(code: .bad_params,
                           message: "series must be \"root\", {voice:{block,index}}, {block} or {send}")
    }
}

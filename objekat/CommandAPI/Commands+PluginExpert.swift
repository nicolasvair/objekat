import Foundation

// MARK: - A plugin's expert bar: its gain reduction, its trims, its gain match

/// The machine's doors onto what the editor bar of a plugin shows (@see PluginExpertBar):
/// `plugin.gain_reduction` reads the read-only parameter the plugin publishes; `plugin.trims` /
/// `plugin.set_trims` / `plugin.nudge_trims` are the two gains around it (engine patch 0045);
/// `plugin.measure_loudness`, `plugin.loudness` and `plugin.gain_match` are the gain match, which
/// reads what was PLAYED (the transport must run, the measurement must be on — the bar switches it
/// on while it is shown, a script does it here).
extension CommandRegistry {

    private func trimError(_ e: Error) -> CommandError {
        switch e as? EditViewModel.TrimError {
        case .unknownPlugin?:           return CommandError(code: .not_found, message: "unknown plugin")
        case .notPlaying?:              return CommandError(code: .invalid_state, message: "the gain match reads what is played: start the transport")
        case .notEnoughSignal(let b)?:  return CommandError(code: .invalid_state, message: "not enough signal above the gate (\(b) of \(EditViewModel.gainMatchMinimumBlocks) blocks of 100 ms)")
        case nil:                       return CommandError(code: .engine_error, message: String(describing: e))
        }
    }

    private func trimsJSON(_ vm: EditViewModel, _ id: UUID) throws -> JSONValue {
        guard let t = vm.pluginTrims(id) else { throw trimError(EditViewModel.TrimError.unknownPlugin) }
        return .object(["plugin": .string(id.uuidString),
                        "input_db": .number(Double(t.input)), "output_db": .number(Double(t.output))])
    }

    private func lufsJSON(_ v: Double) -> JSONValue { v.isFinite ? .number(v) : .null }

    func registerPluginExpertCommands() {

        register("plugin.gain_reduction",
                 summary: "The read-only parameters a plugin publishes, the one its bar reads as gain reduction (remembered per plugin type), and what it says now.",
                 params: [ParamSpec("plugin", "uuid", "A live plugin.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            guard vm.presetTarget(id) != nil else { throw self.trimError(EditViewModel.TrimError.unknownPlugin) }
            let cands = vm.meterParameters(of: id)
            let chosen = vm.gainReductionParameter(of: id, among: cands)
            let value = chosen.flatMap { vm.gainReductionValue(of: id, parameter: $0) }
            return .object([
                "candidates": .array(cands.map { .object(["index": .number(Double($0.index)), "id": .string($0.id), "name": .string($0.name)]) }),
                "chosen": chosen.map { .string($0.id) } ?? .null,
                "text": value.map { .string($0.text) } ?? .null,
                "db": value?.decibels.map { .number($0) } ?? .null
            ])
        }

        register("plugin.choose_gain_reduction",
                 summary: "Chooses which read-only parameter the bar reads as gain reduction, for every plugin of this type (`id` null = none).",
                 params: [ParamSpec("plugin", "uuid", "A live plugin."),
                          ParamSpec("id", "string", required: false, "A candidate's id from plugin.gain_reduction; null or absent = show nothing.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            guard vm.presetTarget(id) != nil else { throw self.trimError(EditViewModel.TrimError.unknownPlugin) }
            let want = try p.optionalString("id")
            let cands = vm.meterParameters(of: id)
            var chosen: PluginMeterParameter? = nil
            if let want {
                guard let c = cands.first(where: { $0.id == want }) else {
                    throw CommandError(code: .not_found, message: "no read-only parameter '\(want)' on this plugin")
                }
                chosen = c
            }
            vm.chooseGainReductionParameter(of: id, chosen)
            return .object(["chosen": chosen.map { .string($0.id) } ?? .null])
        }

        register("plugin.trims",
                 summary: "A plugin's input and output trims, in dB.",
                 params: [ParamSpec("plugin", "uuid", "A live plugin.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            return try self.trimsJSON(vm, try p.uuid("plugin"))
        }

        register("plugin.set_trims",
                 summary: "Sets a plugin's trims (dB, clamped to ±24; an absent one is kept), on it and on every instance actively linked to it. One undo point.",
                 params: [ParamSpec("plugin", "uuid", "A live plugin."),
                          ParamSpec("input", "number", required: false, "Input trim, dB."),
                          ParamSpec("output", "number", required: false, "Output trim, dB.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            guard let cur = vm.pluginTrims(id) else { throw self.trimError(EditViewModel.TrimError.unknownPlugin) }
            let i = try p.optionalDouble("input").map(Float.init) ?? cur.input
            let o = try p.optionalDouble("output").map(Float.init) ?? cur.output
            do { try vm.setPluginTrims(pluginID: id, input: i, output: o) } catch { throw self.trimError(error) }
            return try self.trimsJSON(vm, id)
        }

        register("plugin.nudge_trims",
                 summary: "The coupled gesture: +delta dB on the input trim, -delta on the output (cut so neither leaves ±24). One undo point.",
                 params: [ParamSpec("plugin", "uuid", "A live plugin."),
                          ParamSpec("delta", "number", "dB.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            do { try vm.nudgeCoupledTrims(pluginID: id, deltaDb: Float(try p.double("delta"))) } catch { throw self.trimError(error) }
            return try self.trimsJSON(vm, id)
        }

        register("plugin.measure_loudness",
                 summary: "Switches the K-weighted measurement of a plugin's input and output on or off (the gain match reads it).",
                 params: [ParamSpec("plugin", "uuid", "A live plugin."),
                          ParamSpec("on", "bool", "true = measure.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            guard vm.presetTarget(id) != nil else { throw self.trimError(EditViewModel.TrimError.unknownPlugin) }
            vm.setGainMatchMeasuring(pluginID: id, try p.bool("on"))
            return .object(["on": .bool(try p.bool("on"))])
        }

        register("plugin.loudness",
                 summary: "What the measurement read over the last `seconds` (default 5): K-weighted LUFS entering the plugin (before its input trim) and leaving it (before its output trim), gated at -70 LUFS.",
                 params: [ParamSpec("plugin", "uuid", "A live plugin."),
                          ParamSpec("seconds", "number", required: false, "Window, 0.1..12 s.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            guard vm.presetTarget(id) != nil else { throw self.trimError(EditViewModel.TrimError.unknownPlugin) }
            let secs = try p.double("seconds", or: EditViewModel.gainMatchWindowSeconds)
            guard let r = vm.pluginLoudness(pluginID: id, seconds: secs) else {
                return .object(["blocks": .number(0), "input_lufs": .null, "output_lufs": .null])
            }
            return .object(["blocks": .number(Double(r.blocks)),
                            "input_lufs": self.lufsJSON(r.input), "output_lufs": self.lufsJSON(r.output)])
        }

        register("plugin.gain_match",
                 summary: "Sets the plugin's OUTPUT trim so that what leaves it is as loud (K-weighted) as what enters it, over the last 5 s played. Needs the transport running and the measurement on. One undo point.",
                 params: [ParamSpec("plugin", "uuid", "A live plugin.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("plugin")
            do { try vm.gainMatch(pluginID: id) } catch { throw self.trimError(error) }
            return try self.trimsJSON(vm, id)
        }
    }
}

import Foundation

// MARK: - Plugins

/// The HOST of an FX chain is either a timeline object or a bus (a stem or the Main): on the
/// view-model side it is the same `hostID` and the same methods (`chainPlugins`, `updateChainPlugins`).
/// The commands keep that generality — "add a reverb on the Voice stem" and "on this clip" are
/// the same gesture, and telling them apart would only duplicate the vocabulary.
///
/// No command opens a plugin editor: with no window and no graphics context allocated, that
/// would only lead to a crash. Parameters are set through `plugin.set_param`.
extension CommandRegistry {

    func registerPluginCommands() {

        register("plugin.list_available",
                 summary: "Catalogue of the scanned plugins (run plugin.scan if it is empty).",
                 params: [ParamSpec("filter", "string", required: false,
                                    "Keep only the names/manufacturers holding this text."),
                          ParamSpec("instruments_only", "bool", required: false,
                                    "Keep only the instruments (default false).")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let filter = (try p.optionalString("filter"))?.lowercased()
            let instrumentsOnly = try p.bool("instruments_only", or: false)
            let plugins = vm.availablePlugins.filter { plugin in
                if instrumentsOnly && !plugin.isInstrument { return false }
                guard let filter else { return true }
                return plugin.name.lowercased().contains(filter)
                    || plugin.manufacturer.lowercased().contains(filter)
            }
            return .object([
                "plugins": .array(plugins.map { plugin in
                    .object(["name": .string(plugin.name),
                             "manufacturer": .string(plugin.manufacturer),
                             // `identifier` + `format` form the key used to add: that pair is what
                             // `plugin.add` expects, not the name (two formats can share the same
                             // name).
                             "identifier": .string(plugin.identifier),
                             "format": .string(plugin.formatName),
                             "is_instrument": .bool(plugin.isInstrument)])
                }),
                "count": .int(plugins.count),
                "scanning": .bool(vm.isScanning),
            ])
        }

        register("plugin.list",
                 summary: "FX chain of a host (a timeline object OR a stem).",
                 params: [ParamSpec("host", "uuid", "Object or stem carrying the chain.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            guard let plugins = vm.chainPlugins(host) else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            let gains = vm.chainGains(host)
            var payload: [String: JSONValue] = [
                "host": .string(host.uuidString),
                "is_stem": .bool(vm.isStemHost(host)),
                "plugins": .array(plugins.map(CommandAdapters.pluginPayload)),
                "chain_in_db": .number(Double(gains.inDb)),
                "chain_out_db": .number(Double(gains.outDb)),
            ]
            if let object = vm.find(id: host) {
                payload["instruments"] = .array(object.instruments.map(CommandAdapters.pluginPayload))
            }
            return .object(payload)
        }

        register("plugin.add",
                 summary: "Adds a plugin at the end of a host's chain.",
                 params: [ParamSpec("host", "uuid", "Receiving object or stem."),
                          ParamSpec("identifier", "string", required: false,
                                    "Exact identifier (see plugin.list_available)."),
                          ParamSpec("name", "string", required: false,
                                    "Failing an identifier: the first plugin whose name matches."),
                          ParamSpec("format", "string", required: false,
                                    "Format to settle ties (AudioUnit, VST3, TracktionInternal…).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            guard let before = vm.chainPlugins(host) else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            let available = try CommandAdapters.resolvePlugin(p, in: vm)
            vm.addPlugin(objectID: host, available: available)
            let after = vm.chainPlugins(host) ?? []
            // `addPlugin` removes the entry if the engine cannot instantiate it: not checking
            // would have a command return "ok" while it laid nothing down.
            guard after.count > before.count, let added = after.last else {
                throw CommandError(code: .engine_error,
                                   message: "the engine could not instantiate '\(available.name)'")
            }
            return .object(["host": .string(host.uuidString),
                            "plugin": CommandAdapters.pluginPayload(added)])
        }

        register("plugin.remove",
                 summary: "Removes a plugin from a host's chain.",
                 params: [ParamSpec("host", "uuid", "Carrying object or stem."),
                          ParamSpec("plugin", "uuid", "Plugin to remove.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)
            vm.removePlugin(objectID: host, pluginID: pluginID)
            return .object(["host": .string(host.uuidString),
                            "remaining": .int((vm.chainPlugins(host) ?? []).count)])
        }

        register("plugin.toggle",
                 summary: "Enables or bypasses a plugin (a toggle, without recompiling the chain).",
                 params: [ParamSpec("host", "uuid", "Carrying object or stem."),
                          ParamSpec("plugin", "uuid", "Target plugin.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            let plugin = try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)
            vm.togglePluginEnabled(objectID: host, pluginID: pluginID)
            return .object(["plugin": .string(pluginID.uuidString),
                            "enabled": .bool(!plugin.isEnabled)])
        }

        register("plugin.move",
                 summary: "Moves a plugin from one host to another (the plugin's state follows).",
                 params: [ParamSpec("from", "uuid", "Source host."),
                          ParamSpec("plugin", "uuid", "Plugin to move."),
                          ParamSpec("to", "uuid", "Receiving host.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let from = try p.uuid("from")
            let to = try p.uuid("to")
            let pluginID = try p.uuid("plugin")
            try CommandAdapters.requirePlugin(pluginID, on: from, in: vm)
            guard vm.chainPlugins(to) != nil else {
                throw CommandError(code: .not_found, message: "unknown host: \(to.uuidString)")
            }
            vm.movePlugin(sourceObjectID: from, pluginID: pluginID, targetObjectID: to)
            return .object(["from": .string(from.uuidString), "to": .string(to.uuidString)])
        }

        register("plugin.copy",
                 summary: "Copies a plugin to another host (an independent instance).",
                 params: [ParamSpec("from", "uuid", "Source host."),
                          ParamSpec("plugin", "uuid", "Plugin to copy."),
                          ParamSpec("to", "uuid", "Receiving host.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let from = try p.uuid("from")
            let to = try p.uuid("to")
            let pluginID = try p.uuid("plugin")
            try CommandAdapters.requirePlugin(pluginID, on: from, in: vm)
            guard vm.chainPlugins(to) != nil else {
                throw CommandError(code: .not_found, message: "unknown host: \(to.uuidString)")
            }
            vm.copyPlugin(sourceObjectID: from, pluginID: pluginID, targetObjectID: to)
            return .object(["from": .string(from.uuidString), "to": .string(to.uuidString)])
        }

        register("plugin.link",
                 summary: "Copies a plugin to another host AND LINKS IT: from then on the two "
                        + "instances share their parameters.",
                 params: [ParamSpec("from", "uuid", "Source host."),
                          ParamSpec("plugin", "uuid", "Source plugin."),
                          ParamSpec("to", "uuid", "Receiving host.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let from = try p.uuid("from")
            let to = try p.uuid("to")
            let pluginID = try p.uuid("plugin")
            try CommandAdapters.requirePlugin(pluginID, on: from, in: vm)
            guard vm.chainPlugins(to) != nil else {
                throw CommandError(code: .not_found, message: "unknown host: \(to.uuidString)")
            }
            vm.linkAcrossObjects(sourceObjectID: from, sourcePluginID: pluginID, targetObjectID: to)
            return .object(["links": .int(vm.linkSiblings(of: pluginID).count)])
        }

        register("plugin.unlink",
                 summary: "Detaches a plugin from its link group (it becomes independent again).",
                 params: [ParamSpec("host", "uuid", "Carrying host."),
                          ParamSpec("plugin", "uuid", "Plugin to detach.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            let plugin = try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)
            guard plugin.isLinked else {
                throw CommandError(code: .invalid_state, message: "plugin already independent")
            }
            vm.unlinkPlugin(objectID: host, pluginID: pluginID)
            return .object(["plugin": .string(pluginID.uuidString), "linked": .bool(false)])
        }

        register("plugin.get_params",
                 summary: "Automatable parameters of a live instance (read from the engine).",
                 params: [ParamSpec("plugin", "uuid", "Target plugin.")]) { p in
            _ = try CommandContext.shared.requireEngine()
            let vm = try CommandContext.shared.requireViewModel()
            let pluginID = try p.uuid("plugin")
            let params = vm.getPluginParams(pluginID: pluginID)
            return .object([
                "plugin": .string(pluginID.uuidString),
                "params": .array(params.map { param in
                    .object(["index": .int(param.index),
                             "name": .string(param.name),
                             "value": .number(Double(param.value)),
                             "min": .number(Double(param.min)),
                             "max": .number(Double(param.max)),
                             "display": .string(param.valueString)])
                }),
                "count": .int(params.count),
            ])
        }

        register("plugin.set_param",
                 summary: "Writes a parameter of a live instance (by index).",
                 params: [ParamSpec("plugin", "uuid", "Target plugin."),
                          ParamSpec("index", "int", "Parameter index (see plugin.get_params)."),
                          ParamSpec("value", "number", "New value, within [min, max].")],
                 // The interface doesn't make a parameter move undoable: the state lives in the
                 // engine instance, and is only captured into the model at serialisation points
                 // (`withCapturedPluginStates`). Claiming otherwise here would give an undo that
                 // puts nothing back.
                 undo: .none) { p in
            _ = try CommandContext.shared.requireEngine()
            let vm = try CommandContext.shared.requireViewModel()
            let pluginID = try p.uuid("plugin")
            let index = try p.int("index")
            let params = vm.getPluginParams(pluginID: pluginID)
            guard let target = params.first(where: { $0.index == index }) else {
                throw CommandError(code: .not_found,
                                   message: "unknown parameter \(index) (\(params.count) available)")
            }
            let value = Float(try p.double("value")).clamped(to: target.min...target.max)
            vm.setPluginParam(pluginID: pluginID, index: index, value: value)
            return .object(["plugin": .string(pluginID.uuidString),
                            "index": .int(index),
                            "value": .number(Double(value))])
        }

        // MARK: instruments (MIDI clips)

        register("instrument.set",
                 summary: "Sets the virtual instrument of a MIDI clip (replacing the previous one).",
                 params: [ParamSpec("id", "uuid", "Target MIDI clip."),
                          ParamSpec("identifier", "string", required: false, "Exact identifier."),
                          ParamSpec("name", "string", required: false, "Name, failing an identifier."),
                          ParamSpec("format", "string", required: false, "Format to settle ties.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id), object.isMIDI else {
                throw CommandError(code: .not_found, message: "unknown MIDI clip: \(id.uuidString)")
            }
            let available = try CommandAdapters.resolvePlugin(p, in: vm)
            vm.setInstrument(objectID: id, available: available)
            guard let instrument = vm.find(id: id)?.instruments.first else {
                throw CommandError(code: .engine_error,
                                   message: "the engine could not instantiate '\(available.name)'")
            }
            return .object(["id": .string(id.uuidString),
                            "instrument": CommandAdapters.pluginPayload(instrument)])
        }

        register("instrument.remove",
                 summary: "Removes the virtual instrument from a MIDI clip.",
                 params: [ParamSpec("id", "uuid", "Target MIDI clip.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id), object.isMIDI else {
                throw CommandError(code: .not_found, message: "unknown MIDI clip: \(id.uuidString)")
            }
            guard !object.instruments.isEmpty else {
                throw CommandError(code: .invalid_state, message: "no instrument to remove")
            }
            vm.removeInstrument(objectID: id)
            return .object(["id": .string(id.uuidString)])
        }
    }
}

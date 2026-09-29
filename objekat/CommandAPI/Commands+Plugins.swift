import AppKit
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
                 // `.handled` since 15 September 2026: the method pushes its own point now, and
                 // the bus wrapping it a second time would cost two ⌘Z for one bypass.
                 undo: .handled) { p in
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
                          ParamSpec("plugin", "uuid", required: false, "Plugin to move."),
                          ParamSpec("plugins", "uuid[]", required: false,
                                    "Several plugins at once (one undo step, the source chain's "
                                  + "order kept). Replaces 'plugin'."),
                          ParamSpec("to", "uuid", "Receiving host.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let from = try p.uuid("from")
            let to = try p.uuid("to")
            let ids = try CommandAdapters.transferTargets(p, on: from, in: vm)
            guard vm.chainPlugins(to) != nil else {
                throw CommandError(code: .not_found, message: "unknown host: \(to.uuidString)")
            }
            let placed = vm.transferPlugins(ids, from: from, to: to, mode: .move)
            return .object(["from": .string(from.uuidString), "to": .string(to.uuidString),
                            "plugins": .array(placed.map { .string($0.uuidString) }),
                            "count": .int(placed.count)])
        }

        register("plugin.copy",
                 summary: "Copies a plugin to another host (an independent instance).",
                 params: [ParamSpec("from", "uuid", "Source host."),
                          ParamSpec("plugin", "uuid", required: false, "Plugin to copy."),
                          ParamSpec("plugins", "uuid[]", required: false,
                                    "Several plugins at once. Replaces 'plugin'."),
                          ParamSpec("to", "uuid", "Receiving host.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let from = try p.uuid("from")
            let to = try p.uuid("to")
            let ids = try CommandAdapters.transferTargets(p, on: from, in: vm)
            guard vm.chainPlugins(to) != nil else {
                throw CommandError(code: .not_found, message: "unknown host: \(to.uuidString)")
            }
            let placed = vm.transferPlugins(ids, from: from, to: to, mode: .copy)
            return .object(["from": .string(from.uuidString), "to": .string(to.uuidString),
                            "plugins": .array(placed.map { .string($0.uuidString) }),
                            "count": .int(placed.count)])
        }

        register("plugin.link",
                 summary: "Copies a plugin to another host AND LINKS IT: from then on the two "
                        + "instances share their parameters.",
                 params: [ParamSpec("from", "uuid", "Source host."),
                          ParamSpec("plugin", "uuid", required: false, "Source plugin."),
                          ParamSpec("plugins", "uuid[]", required: false,
                                    "Several plugins at once, each linked to its own copy. "
                                  + "Replaces 'plugin'."),
                          ParamSpec("to", "uuid", "Receiving host.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let from = try p.uuid("from")
            let to = try p.uuid("to")
            let ids = try CommandAdapters.transferTargets(p, on: from, in: vm)
            guard vm.chainPlugins(to) != nil else {
                throw CommandError(code: .not_found, message: "unknown host: \(to.uuidString)")
            }
            let placed = vm.transferPlugins(ids, from: from, to: to, mode: .link)
            return .object(["links": .int(vm.linkSiblings(of: ids[0]).count),
                            "plugins": .array(placed.map { .string($0.uuidString) }),
                            "count": .int(placed.count)])
        }

        // The DROP itself, and not merely what it ends up calling. `plugin.move|copy|link` reach
        // `transferPlugins` directly; a hand reaches it through `acceptPluginDrop`, which is the
        // one door both places the hand can let go of share — a timeline object, and a bus's strip
        // in the toolbar. What only this command can assert is what that door adds on top of the
        // transfer: an instrument going to its SLOT rather than into the chain, and the selection
        // following its cards into the target when it was the selection that was dragged.
        register("plugin.drop",
                 summary: "Drops a plugin (or the whole selection) onto a host, exactly as a drag "
                        + "released over a timeline object or a bus's strip does.",
                 params: [ParamSpec("from", "uuid", "Source host."),
                          ParamSpec("plugin", "uuid", required: false, "Dragged plugin."),
                          ParamSpec("plugins", "uuid[]", required: false,
                                    "Several plugins at once. Replaces 'plugin'."),
                          ParamSpec("to", "uuid", "Host the drag is released over."),
                          ParamSpec("mode", "string", required: false,
                                    "move (default, no modifier) | copy (⌥) | link (⌘).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let from = try p.uuid("from")
            let to = try p.uuid("to")
            let ids = try CommandAdapters.transferTargets(p, on: from, in: vm)
            let mode = try p.string("mode", or: "move")
            let flags: NSEvent.ModifierFlags
            switch mode {
            case "move": flags = []
            case "copy": flags = .option
            case "link": flags = .command
            default: throw CommandError(code: .bad_params,
                                        message: "mode must be move, copy or link")
            }
            let payload = PluginDragPayload(sourceObjectID: from, pluginID: ids[0], pluginIDs: ids)
            let placed = vm.acceptPluginDrop(payload, on: to, modifiers: flags)
            return .object(["placed": .bool(placed),
                            "to": .string(to.uuidString),
                            "selection": .array(vm.orderedSelectedPluginIDs().map { .string($0.uuidString) }),
                            "selection_host": vm.selectedPluginHostID.map { .string($0.uuidString) } ?? .null])
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

        // MARK: a selection of cards
        //
        // The signal view selects several cards at a time — a rectangle drawn on the canvas, ⇧ for
        // the box that holds them, ⌘ one by one. What the mouse does there is geometry and stays in
        // the view; what it RESULTS IN is this selection, which lives in the view-model, and that is
        // what these commands drive. Everything below acts on it in ONE undo step.
        //
        // The selection also carries the keyboard: as long as a host is named, ⌫ ⌘C ⌘V ⌘D aim at
        // the cards rather than at the timeline's objects (@see EditViewModel.setPluginSelection).
        // `plugin.select` with an empty list therefore means something precise — claim the keyboard
        // for that chain, choose nothing — and `plugin.deselect` gives it back.

        register("plugin.select",
                 summary: "Selects cards in a host's chain (and gives that chain the keyboard).",
                 params: [ParamSpec("host", "uuid", "Object or stem carrying the chain."),
                          ParamSpec("plugins", "uuid[]", required: false,
                                    "Cards to select. Absent or empty: selects nothing, but the "
                                  + "chain still takes the keyboard."),
                          ParamSpec("mode", "string", required: false,
                                    "replace (default) · add · toggle. 'add' and 'toggle' only "
                                  + "build on a selection already on THIS host.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            guard vm.chainPlugins(host) != nil else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            let ids = p.raw["plugins"] == nil ? [] : try p.uuids("plugins")
            for id in ids { try CommandAdapters.requirePlugin(id, on: host, in: vm) }
            let mode = try p.string("mode", or: "replace")
            let base = vm.selectedPluginHostID == host ? vm.selectedPluginIDs : []
            switch mode {
            case "replace": vm.setPluginSelection(Set(ids), host: host)
            case "add":     vm.setPluginSelection(base.union(ids), host: host)
            case "toggle":  vm.setPluginSelection(base.symmetricDifference(ids), host: host)
            default:
                throw CommandError(code: .bad_params,
                                   message: "unknown mode '\(mode)' (replace · add · toggle)")
            }
            return .object(["host": .string(host.uuidString),
                            "plugins": .array(vm.orderedSelectedPluginIDs().map { .string($0.uuidString) }),
                            "count": .int(vm.selectedPluginIDs.count)])
        }

        register("plugin.selection",
                 summary: "The cards selected, in the chain's reading order.",
                 params: []) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            var payload: [String: JSONValue] = [
                "plugins": .array(vm.orderedSelectedPlugins().map(CommandAdapters.pluginPayload)),
                "count": .int(vm.orderedSelectedPlugins().count),
                "has_keyboard": .bool(vm.pluginSurfaceHasKeyboard),
                "clipboard": .int(vm.pluginClipboard.count),
            ]
            payload["host"] = vm.selectedPluginHostID.map { .string($0.uuidString) } ?? .null
            return .object(payload)
        }

        register("plugin.deselect",
                 summary: "Clears the card selection and gives the keyboard back to the timeline.",
                 params: [], undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            vm.clearPluginSelection()
            return .object(["host": .null, "count": .int(0)])
        }

        register("plugin.remove_selected",
                 summary: "Removes every selected card (one undo step for the whole batch).",
                 params: [], undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let host = vm.selectedPluginHostID
            let removed = vm.removeSelectedPlugins()
            return .object(["removed": .int(removed),
                            "remaining": .int(host.flatMap { vm.chainPlugins($0) }?.count ?? 0)])
        }

        register("plugin.toggle_selected",
                 summary: "Bypasses or re-enables every selected card. Mixed states go to OFF: "
                        + "if a single one is still on, they all go off. ONE undo step.",
                 params: [], undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard let enabled = vm.toggleSelectedPluginsEnabled() else {
                throw CommandError(code: .invalid_state, message: "no card selected")
            }
            return .object(["enabled": .bool(enabled),
                            "count": .int(vm.selectedPluginIDs.count)])
        }

        register("plugin.duplicate_selected",
                 summary: "Duplicates the selection in place, just after the LAST selected card "
                        + "and in its own series. The copies become the selection.",
                 params: [], undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let made = vm.duplicateSelectedPlugins()
            guard !made.isEmpty else {
                throw CommandError(code: .invalid_state, message: "no card selected")
            }
            return .object(["plugins": .array(made.map { .string($0.uuidString) }),
                            "count": .int(made.count)])
        }

        register("plugin.copy_selected",
                 summary: "Puts the selection on the plugin clipboard (with its live state).",
                 params: [], undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let n = vm.copySelectedPluginsToClipboard()
            guard n > 0 else {
                throw CommandError(code: .invalid_state, message: "no card selected")
            }
            return .object(["clipboard": .int(n)])
        }

        register("plugin.paste",
                 summary: "Pastes the plugin clipboard into a chain, after the last selected card "
                        + "of that chain or at its end.",
                 params: [ParamSpec("host", "uuid", required: false,
                                    "Receiving chain. Default: the selection's host.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            guard let host = try p.optionalUUID("host") ?? vm.selectedPluginHostID else {
                throw CommandError(code: .bad_params, message: "no host: name 'host'")
            }
            guard vm.chainPlugins(host) != nil else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            guard !vm.pluginClipboard.isEmpty else {
                throw CommandError(code: .invalid_state, message: "plugin clipboard empty")
            }
            let made = vm.pastePlugins(into: host)
            return .object(["host": .string(host.uuidString),
                            "plugins": .array(made.map { .string($0.uuidString) }),
                            "count": .int(made.count)])
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

        register("plugin.get_state",
                 summary: """
                 The LIVE binary state (chunk, standard base64) of an external plugin instance, read off the \
                 engine — what a save or an undo snapshot would freeze, and the only place a \
                 setting the host cannot see (a Pro-Q 4 band's "Spectral" switch) exists at all. \
                 The way to check two members of an FX link agree: their chunks are equal. \
                 `invalid_state` for a built-in plugin or an instance not loaded yet.
                 """,
                 params: [ParamSpec("plugin", "uuid", "Target plugin instance."),
                          ParamSpec("include_chunk", "bool", required: false,
                                    "false to answer only the size (default true).")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let pluginID = try p.uuid("plugin")
            let includeChunk = try p.bool("include_chunk", or: true)
            guard let chunk = engine.pluginStateChunkBase64(pluginID.uuidString) else {
                throw CommandError(code: .invalid_state,
                                   message: "no readable state for \(pluginID.uuidString) "
                                          + "(built-in, not loaded yet, or the unit refuses its state)")
            }
            let size = Data(base64Encoded: chunk)?.count ?? 0
            var out: [String: JSONValue] = ["plugin": .string(pluginID.uuidString),
                                            "size": .int(size)]
            if includeChunk { out["state"] = .string(chunk) }
            return .object(out)
        }

        #if DEBUG
        register("debug.plugin_inject_state",
                 summary: """
                 DEBUG. Lays a binary chunk (standard base64, as `plugin.get_state` returns it) on a live \
                 external plugin instance with NO link sync and NO baseline: a change of state \
                 that nothing announced, like the one a native GUI makes. The resting-state sync \
                 of an FX link is what is meant to catch it (`debug.link_state_tick`).
                 """,
                 params: [ParamSpec("plugin", "uuid", "Target plugin instance."),
                          ParamSpec("state", "string", "The chunk, base64.")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let pluginID = try p.uuid("plugin")
            guard engine.debugInjectPluginStateChunk(try p.string("state"),
                                                      forPlugin: pluginID.uuidString) else {
                throw CommandError(code: .invalid_state,
                                   message: "cannot inject into \(pluginID.uuidString) "
                                          + "(unknown, built-in, or not loaded yet)")
            }
            return .object(["plugin": .string(pluginID.uuidString)])
        }

        register("debug.link_state_tick",
                 summary: """
                 DEBUG. One tick of the FX-link resting-state sync on one instance: reads its chunk \
                 and, if it differs from the reference, lays it on the other members of its group. \
                 `force` false (default) demands stability like the 500 ms timer (no open gesture, \
                 same chunk as the previous tick — so it takes two ticks and answers `pending` \
                 in between); true pushes as an editor close or a save would. `pushed` lists the \
                 instances actually overwritten.
                 """,
                 params: [ParamSpec("plugin", "uuid", "The instance whose state changed."),
                          ParamSpec("force", "bool", required: false, "Default false.")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let pluginID = try p.uuid("plugin")
            let pushed = engine.debugLinkStateTick(pluginID.uuidString,
                                                    force: try p.bool("force", or: false))
            return .object(["plugin": .string(pluginID.uuidString),
                            "pushed": .array(pushed.map { .string($0) }),
                            "pending": .bool(engine.isLinkStatePending(pluginID.uuidString))])
        }

        register("debug.link_state",
                 summary: """
                 DEBUG. The resting-state sync's counters: pushes (total and by source instance), \
                 the reference chunk size held per instance, gestures open, instances pending, the \
                 plugin models learned unstable, and whether the 500 ms timer is running.
                 """,
                 undo: .none) { _ in
            let engine = try CommandContext.shared.requireEngine()
            let info = engine.linkStateDebugInfo()
            @MainActor func counts(_ key: String) -> JSONValue {
                let d = info[key] as? [String: NSNumber] ?? [:]
                return .object(d.mapValues { .int($0.intValue) })
            }
            func names(_ key: String) -> JSONValue {
                .array((info[key] as? [String] ?? []).sorted().map { .string($0) })
            }
            return .object(["pushes_total": .int((info["pushes_total"] as? NSNumber)?.intValue ?? 0),
                            "pushes": counts("pushes"),
                            "baselines": counts("baselines"),
                            "gesture_open": counts("gesture_open"),
                            "pending": names("pending"),
                            "unstable_types": names("unstable_types"),
                            "timer_running": .bool((info["timer_running"] as? NSNumber)?.boolValue ?? false)])
        }
        #endif

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

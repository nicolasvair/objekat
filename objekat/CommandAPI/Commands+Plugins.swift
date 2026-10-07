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
                             "is_instrument": .bool(plugin.isInstrument),
                             // Can act as an ARA source (Melodyne VST3 only): known without loading any module.
                             "ara": .bool(plugin.isARA)])
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
            let status = vm.bridgeStatusNow()
            var payload: [String: JSONValue] = [
                "host": .string(host.uuidString),
                "is_stem": .bool(vm.isStemHost(host)),
                "plugins": .array(plugins.map { CommandAdapters.pluginPayload($0, bridgeStatus: status) }),
                "chain_in_db": .number(Double(gains.inDb)),
                "chain_out_db": .number(Double(gains.outDb)),
            ]
            if let object = vm.find(id: host) {
                payload["instruments"] = .array(object.instruments.map { CommandAdapters.pluginPayload($0, bridgeStatus: status) })
            }
            return .object(payload)
        }

        register("plugin.sidechain_sources",
                 summary: """
                 The sources a plugin's sidechain input can be keyed by (the audio bridge): `can_sidechain` \
                 says whether the LIVE instance has a sidechain input at all (an AU still loading says false \
                 — wait and ask again); `current` is the source now keyed (or null); `sources` lists what \
                 is allowed (`{id, kind, name}`, kind object / group / stem), `refused` what is not, with \
                 the reason (`ancestorSource`, `selfSource`, `cycle`, `auxSource`…). The Main is never a \
                 source and is not listed. Reads only. Instruments (a MIDI object's virtual \
                 instrument) are not supported yet: only leaf plugins of a chain.
                 """,
                 params: [ParamSpec("host", "uuid", "Object or stem carrying the plugin."),
                          ParamSpec("plugin", "uuid", "Leaf plugin of the chain (instruments: not yet).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            let plugin = try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)
            var allowed: [JSONValue] = [], refused: [JSONValue] = []
            for c in vm.sidechainCandidates(host: host, plugin: pluginID) {
                var entry: [String: JSONValue] = ["id": .string(c.id.uuidString),
                                                  "kind": .string(c.kind.rawValue),
                                                  "name": .string(c.name)]
                if let why = c.refusal { entry["reason"] = .string(why.rawValue); refused.append(.object(entry)) }
                else { allowed.append(.object(entry)) }
            }
            return .object(["host": .string(host.uuidString), "plugin": .string(pluginID.uuidString),
                            "can_sidechain": .bool(engine.pluginCanSidechain(pluginID.uuidString)),
                            "current": .stringOrNull(plugin.sidechain?.sourceID.uuidString),
                            "sources": .array(allowed), "refused": .array(refused)])
        }

        register("plugin.set_sidechain",
                 summary: """
                 Keys a plugin's sidechain input by an object or a stem (tapped after its fader and its \
                 window — what is heard of it), or clears it (`source` null or absent). Refused \
                 (`bad_params`, the reason in `details.reason`) when the rules say no: the source contains \
                 the host (`ancestorSource`), is the host (`selfSource`), would close a loop (`cycle`), is an \
                 aux or the Main, or does not exist. `invalid_state`: the live plugin has no sidechain \
                 input (or is still loading). One undo step; undoing it does not rebuild the object. \
                 Answers `{ok, active, reason}`. Instruments are not supported yet (only leaf plugins \
                 of a chain).
                 """,
                 params: [ParamSpec("host", "uuid", "Object or stem carrying the plugin."),
                          ParamSpec("plugin", "uuid", "Leaf plugin of the chain (instruments: not yet)."),
                          ParamSpec("source", "uuid", required: false, "The keying object or stem; null clears.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)
            var source: UUID? = nil
            if let raw = p.raw["source"], raw != .null { source = try p.uuid("source") }
            do {
                try vm.setSidechain(host: host, plugin: pluginID, source: source)
            } catch BridgeSidechainError.refused(let why) {
                throw CommandError(code: .bad_params, message: "sidechain source refused: \(why.rawValue)",
                                   details: .object(["reason": .string(why.rawValue)]))
            } catch BridgeSidechainError.cannotSidechain {
                throw CommandError(code: .invalid_state,
                                   message: "plugin \(pluginID.uuidString) has no sidechain input (or is still loading)")
            } catch BridgeSidechainError.notAPlugin {
                throw CommandError(code: .not_found, message: "unknown plugin: \(pluginID.uuidString)")
            }
            let why = vm.bridgeStatusNow()[pluginID]
            return .object(["ok": .bool(true), "active": .bool(source != nil && why == nil),
                            "reason": .stringOrNull(why?.rawValue)])
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
        // `transferPlugins` directly; a hand reaches it through `performPluginDrop`, which is the
        // one door every place the hand can let go of shares — a timeline object, a bus's strip in the
        // toolbar, a cable / a card / a bin's header of the signal view. What only these commands can
        // assert is what that door adds on top of the transfer: an instrument going to its SLOT rather
        // than into the chain, a bin's block moving as one piece, plugins joining or leaving a bin, and
        // the selection following its cards when it was the selection that was dragged.
        register("plugin.drop",
                 summary: "Drops a plugin, the whole selection or an FX link's block onto a host, exactly as a "
                        + "drag released over a timeline object or a bus's strip does.",
                 params: [ParamSpec("from", "uuid", "Source host."),
                          ParamSpec("plugin", "uuid", required: false,
                                    "Dragged plugin — or an FX link's block id (what the bin's header carries)."),
                          ParamSpec("plugins", "uuid[]", required: false,
                                    "Several plugins at once. Replaces 'plugin'."),
                          ParamSpec("to", "uuid", "Host the drag is released over."),
                          ParamSpec("mode", "string", required: false,
                                    "move (default, no modifier) | copy (⌥) | link (⌘).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let from = try p.uuid("from")
            let to = try p.uuid("to")
            let ids = try CommandAdapters.dropTargets(p, on: from, in: vm)
            let flags = try CommandAdapters.dropModifiers(try p.string("mode", or: "move"))
            let payload = PluginDragPayload(sourceObjectID: from, pluginID: ids[0], pluginIDs: ids)
            let outcome = vm.pluginDropOutcome(payload, toHost: to, at: .hostEnd, flags: flags)
            let placed = vm.acceptPluginDrop(payload, on: to, modifiers: flags)
            return .object(["placed": .bool(placed),
                            "outcome": .string(outcome.apiName),
                            "refused": .bool(outcome.isRefusal),
                            "reason": JSONValue.stringOrNull(outcome.refusalReason),
                            "to": .string(to.uuidString),
                            "selection": .array(vm.orderedSelectedPluginIDs().map { .string($0.uuidString) }),
                            "selection_host": vm.selectedPluginHostID.map { .string($0.uuidString) } ?? .null])
        }

        // The drop at a PLACE of the signal view — a cable, a card, a bin's header — with `dry_run`
        // returning what the cursor and the band would say (the resolver's answer) without touching
        // anything. The same door as the hand's (@see EditViewModel.performPluginDrop).
        register("plugin.drop_at",
                 summary: "Drops a plugin, the selection or an FX link's block at a precise place of a host's "
                        + "chain: its root series, an FX link's block or a parallel branch. `dry_run` answers "
                        + "what the drop would do (outcome, refusal reason) and changes nothing.",
                 params: [ParamSpec("from", "uuid", "Source host."),
                          ParamSpec("plugin", "uuid", required: false,
                                    "Dragged plugin — or an FX link's block id."),
                          ParamSpec("plugins", "uuid[]", required: false,
                                    "Several plugins at once. Replaces 'plugin'."),
                          ParamSpec("host", "uuid", "Host whose chain receives the drop."),
                          ParamSpec("series", "string|object", required: false,
                                    "Where: \"root\" (default), {\"block\": <FX link block id>} (into the bin; "
                                  + "without 'at' it lands at its end, like a drop on the header) or "
                                  + "{\"voice\": <parallel block id>, \"index\": <branch>}. "
                                  + "Absent = the host as a whole (the end of its root series)."),
                          ParamSpec("at", "int", required: false,
                                    "Index in that series where the first card lands (default: the end)."),
                          ParamSpec("mode", "string", required: false,
                                    "move (default, no modifier) | copy (⌥) | link (⌘)."),
                          ParamSpec("dry_run", "bool", required: false,
                                    "Only resolve: return the outcome, change nothing (default false).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let from = try p.uuid("from")
            let host = try p.uuid("host")
            guard let chain = vm.chainPlugins(host) else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            let ids = try CommandAdapters.dropTargets(p, on: from, in: vm)
            let flags = try CommandAdapters.dropModifiers(try p.string("mode", or: "move"))
            let site = try CommandAdapters.dropSite(p, chain: chain)
            let payload = PluginDragPayload(sourceObjectID: from, pluginID: ids[0], pluginIDs: ids)
            let outcome = vm.pluginDropOutcome(payload, toHost: host, at: site, flags: flags)
            var result: [String: JSONValue] = ["outcome": .string(outcome.apiName),
                                               "refused": .bool(outcome.isRefusal)]
            if let why = outcome.refusalReason { result["reason"] = .string(why) }
            if try p.bool("dry_run", or: false) {
                result["placed"] = .bool(false)
                result["dry_run"] = .bool(true)
                return .object(result)
            }
            let placed = vm.performPluginDrop(payload, on: host, at: site, modifiers: flags)
            result["placed"] = .bool(placed)
            result["selection"] = .array(vm.orderedSelectedPluginIDs().map { .string($0.uuidString) })
            result["selection_host"] = vm.selectedPluginHostID.map { .string($0.uuidString) } ?? .null
            return .object(result)
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
                "plugins": .array(vm.orderedSelectedPlugins().map { CommandAdapters.pluginPayload($0) }),
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

        register("debug.plugin_force_processor_changed",
                 summary: """
                 DEBUG. Makes a live external plugin instance announce "my processor changed" to \
                 the engine, as an AudioUnit does — late, on its own — after a state has been \
                 restored (`kAudioUnitProperty_PresentPreset`). `details` "program" (default) is that \
                 case: a program change and nothing about the parameter LIST; "paraminfo" also says \
                 the list changed. It turns a race (the notification arrives some 50 ms after the \
                 load settles, or not) into a call. An engine that rebuilds the parameter list on \
                 every such notification (without patch 0035) then reads the factory defaults back, \
                 and an FX link's mirror writes them into the other members; with 0035, "program" \
                 moves nothing, and with 0036 neither does "paraminfo" (the AU re-announces its real \
                 values instead of the rebuilt list's defaults). Wait ~1 s before reading the result \
                 (the engine's update is asynchronous).
                 """,
                 params: [ParamSpec("plugin", "uuid", "Target plugin instance."),
                          ParamSpec("details", "string", required: false,
                                    "\"program\" (default) or \"paraminfo\".")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let pluginID = try p.uuid("plugin")
            let details = try p.string("details", or: "program")
            guard details == "program" || details == "paraminfo" else {
                throw CommandError(code: .bad_params,
                                   message: "details must be \"program\" or \"paraminfo\"")
            }
            guard engine.debugForcePluginProcessorChanged(pluginID.uuidString,
                                                          paramInfo: details == "paraminfo") else {
                throw CommandError(code: .invalid_state,
                                   message: "cannot force on \(pluginID.uuidString) "
                                          + "(unknown, built-in, or not loaded yet)")
            }
            return .object(["plugin": .string(pluginID.uuidString), "details": .string(details)])
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
                 plugin models learned unstable, and whether the 500 ms timer is running. Plus the \
                 parameter mirror's: `param_propagations` (changes a hand made and the mirror carried \
                 to the group) and `param_refused` (changes an instance announced on its own — a \
                 state laid, a program, a rebuilt parameter list, automation — and that stayed \
                 with it), and `authority` (group → the instance whose state the bin's definition \
                 takes; a group absent = nothing edited since it was armed).
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
                            "param_propagations": .int((info["param_propagations"] as? NSNumber)?.intValue ?? 0),
                            "param_refused": .int((info["param_refused"] as? NSNumber)?.intValue ?? 0),
                            "authority": .object((info["authority"] as? [String: String] ?? [:])
                                                    .mapValues { .string($0) }),
                            "timer_running": .bool((info["timer_running"] as? NSNumber)?.boolValue ?? false)])
        }

        register("debug.plugin_id_audit",
                 summary: """
                 DEBUG. The plugin-id uniqueness audit: `duplicates` lists every plugin id held more \
                 than once in the live project (leaves, rack carriers, FX link blocks and their \
                 instances, instruments, bus chains) with the hosts holding it; `count` is their \
                 number. `engine_foreign_refusals` counts the compiles that refused to move a key \
                 another host's chain holds. A sound project answers 0 and 0 — the load repairs a \
                 file that does not (`project.load_status` `last_load.repaired_plugin_ids`).
                 """,
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let dups = vm.duplicatePluginIDs()
            return .object(["duplicates": .array(dups.map { d in
                                .object(["id": .string(d.id.uuidString),
                                         "hosts": .array(d.hosts.map { .string($0.uuidString) })])
                            }),
                            "count": .int(dups.count),
                            "engine_foreign_refusals": .int(engine.foreignPluginKeyRefusals())])
        }

        register("debug.bridge_report",
                 summary: """
                 DEBUG. The audio bridge as the engine built it, plus the model's plan. `engine` (null if no \
                 build yet): `build` {id, passes, converged, sample_rate, block_size, gate_edges, \
                 gate_refused}, `taps` [{tap, source, rank, age, cached_age, ring_capacity, ring_generation, \
                 latest_end, runs}], `readers` [{plugin, dest_instance, tap, consumer, rank, l_ref, declared, \
                 source_age, delay, status, alignment_error_samples, blocks_read, blocks_uncovered, \
                 blocks_torn}]. `model`: the plan — `refused` ({plugin: reason}), `root_ranks`, `aux_ranks`, \
                 `inner_ranks`, `stem_ranks`, `taps`. The static numbers say what the graph BELIEVES; what the \
                 ear hears is measured by export. Reads only.
                 """,
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            @MainActor func ranks(_ d: [UUID: Int]) -> JSONValue {
                .object(Dictionary(uniqueKeysWithValues: d.map { ($0.key.uuidString, JSONValue.int($0.value)) }))
            }
            let plan = vm.bridgePlan
            let refused = vm.bridgeRouteStatus
            let model: JSONValue = .object([
                "refused": .object(Dictionary(uniqueKeysWithValues: refused.map { ($0.key.uuidString, JSONValue.string($0.value.rawValue)) })),
                "root_ranks": ranks(plan.rootRanks), "aux_ranks": ranks(plan.auxRanks),
                "inner_ranks": ranks(plan.innerRanks), "stem_ranks": ranks(plan.stemRanks),
                "taps": ranks(plan.taps)])
            let report = JSONValue.fromFoundation(engine.bridgeReport())
            return .object(["engine": report, "model": model])
        }

        register("debug.add_test_plugin",
                 summary: """
                 DEBUG. Adds a MEASURING plugin to a host's chain through the normal model path: \
                 `objKeyProbe` (its output left = the direct signal, its right = the sidechain key, so an \
                 export shows whether the key is aligned) or `latencyTester` (declares and applies a delay, \
                 `latency_ms`). Answers `{plugin}`.
                 """,
                 params: [ParamSpec("host", "uuid", "Receiving object or stem."),
                          ParamSpec("type", "string", "`objKeyProbe` or `latencyTester`."),
                          ParamSpec("latency_ms", "number", required: false, "latencyTester only: the delay.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let host = try p.uuid("host")
            let type = try p.string("type")
            guard type == "objKeyProbe" || type == "latencyTester" else {
                throw CommandError(code: .bad_params, message: "type must be objKeyProbe or latencyTester")
            }
            guard let before = vm.chainPlugins(host) else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            // A TracktionInternal identifier is resolved by type name (resolvedPluginTreeForInfo:).
            let available = AvailablePlugin(name: type, manufacturer: "Tracktion", identifier: type,
                                            formatName: "TracktionInternal")
            vm.addPlugin(objectID: host, available: available)
            guard let added = vm.chainPlugins(host).flatMap({ $0.count > before.count ? $0.last : nil }) else {
                throw CommandError(code: .engine_error, message: "the engine could not instantiate '\(type)'")
            }
            if type == "latencyTester", let ms = try p.optionalDouble("latency_ms") {
                _ = engine.debugSetPluginProperty("time", value: ms / 1000.0, forPlugin: added.id.uuidString)
            }
            return .object(["plugin": .string(added.id.uuidString)])
        }

        register("debug.set_plugin_property",
                 summary: "DEBUG. Sets a numeric property on a live plugin's state (the latency tester's `time`, in seconds).",
                 params: [ParamSpec("plugin", "uuid", "Target plugin."),
                          ParamSpec("property", "string", "Property name."),
                          ParamSpec("value", "number", "Numeric value.")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let pluginID = try p.uuid("plugin")
            guard engine.debugSetPluginProperty(try p.string("property"), value: try p.double("value"),
                                                forPlugin: pluginID.uuidString) else {
                throw CommandError(code: .not_found, message: "no live instance for plugin \(pluginID.uuidString)")
            }
            return .object(["plugin": .string(pluginID.uuidString)])
        }

        register("debug.ara_probe",
                 summary: """
                 DEBUG. ARA probe: does this plugin act as an ARA source. Only a VST3 can (Tracktion's \
                 ARA host only loads VST3; an AudioUnit never is). The module is loaded to read the real \
                 `hasARAExtension`. Answers `has_ara`, \
                 `resolved_identifier` / `resolved_format` / `resolved_name` and, from the module's ARA \
                 factory, `factory_archive_id`, `factory_plugin_name`, `api_generation_lowest` / \
                 `_highest`, `supports_timestretch`. The factory is kept for the session (never \
                 released: ARA must not be initialised twice). Opens no window.
                 """,
                 params: [ParamSpec("identifier", "string", "Exact identifier (see plugin.list_available)."),
                          ParamSpec("format", "string", "'VST3' (an 'AudioUnit' always answers has_ara false)."),
                          ParamSpec("name", "string", required: false,
                                    "Plugin name (defaults to the catalogue's).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let identifier = try p.string("identifier")
            let format = try p.string("format")
            let name = try p.optionalString("name")
                ?? vm.availablePlugins.first(where: { $0.identifier == identifier && $0.formatName == format })?.name
                ?? ""
            let info: [String: Any] = ["identifier": identifier, "format": format, "name": name]
            return JSONValue.fromFoundation(engine.debugARAProbe(info))
        }

        register("debug.plugin_buses",
                 summary: """
                 DEBUG. Sidechain probe: what a live instance really exposes. Tracktion's view \
                 (`can_sidechain`, `te_input_channels` / `te_output_channels` as the graph builder \
                 reads them, `sidechain_source`, `wires`) and, for an AU/VST3, every bus as JUCE \
                 negotiated it (`input_buses` / `output_buses`: name, channels, enabled, \
                 enabled_by_default, main, layout; `total_input_channels`). A plugin whose sidechain \
                 is usable shows a second input bus ENABLED with channels > 0. `loaded` false = an \
                 external instance still loading — ask again. Reads only.
                 """,
                 params: [ParamSpec("plugin", "uuid", "Target plugin (leaf, instrument or bus-chain plugin).")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let pluginID = try p.uuid("plugin")
            guard let info = engine.pluginBusesInfo(pluginID.uuidString) else {
                throw CommandError(code: .not_found,
                                   message: "no live instance for plugin \(pluginID.uuidString)")
            }
            var payload = JSONValue.fromFoundation(info)
            if case .object(var o) = payload {
                o["plugin"] = .string(pluginID.uuidString)
                payload = .object(o)
            }
            return payload
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

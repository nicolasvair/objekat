import AppKit
import Foundation
import CryptoKit

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
            let status = vm.bridgeStatusNow()
            // An audio object's ARA source (Melodyne) comes FIRST, `slot: "ara_source"`: it is what the
            // clip plays through, ahead of its chain.
            var entries = plugins.map { CommandAdapters.pluginPayload($0, bridgeStatus: status) }
            if let source = vm.find(id: host)?.araSource {
                entries.insert(CommandAdapters.araSourcePayload(source, objectID: host, in: vm), at: 0)
            }
            var payload: [String: JSONValue] = [
                "host": .string(host.uuidString),
                "is_stem": .bool(vm.isStemHost(host)),
                "plugins": .array(entries),
            ]
            // A send's mini-chain (INC 3): who it belongs to.
            if vm.find(id: host) == nil, let key = vm.sendChainKey(host) {
                payload["is_send_chain"] = .bool(true)
                payload["sender"] = .string(key.sender.uuidString)
                payload["aux"] = .string(key.aux.uuidString)
            }
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

        register("plugin.channel_layouts",
                 summary: """
                 The width of a plugin's MAIN bus, and which of the three variants it can take: `mono` \
                 (1 in, 1 out), `mono_stereo` (1 in, 2 out), `stereo` (2 in, 2 out). `external` false \
                 (a built-in or in-house plugin) or `loaded` false (the instance is still loading — wait \
                 and ask again) means no variants. `current` is the variant now in force (null for a bus \
                 outside the three, a surround plugin). Each variant carries `supported`; `exact` false \
                 means that answer is best-effort (a VST3 once the playback context is allocated): a \
                 refusal met when applying is remembered and shows as `supported: false` afterwards. \
                 `linked` is how many OTHER instances change together with this one (an FX link's \
                 mirrors, a manual link's peers): a variant is `supported` only if EVERY member takes it. \
                 `playing` true = the change would be refused now. Reads only. Instruments (a MIDI \
                 object's virtual instrument) are not supported: only leaf plugins of a chain.
                 """,
                 params: [ParamSpec("host", "uuid", "Object or stem carrying the plugin."),
                          ParamSpec("plugin", "uuid", "Leaf plugin of the chain.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)
            var payload: [String: JSONValue] = ["host": .string(host.uuidString),
                                                "plugin": .string(pluginID.uuidString),
                                                "playing": .bool(vm.isTransportPlaying)]
            guard let info = engine.pluginChannelInfo(pluginID.uuidString, probeVariants: true) else {
                throw CommandError(code: .invalid_state,
                                   message: "plugin \(pluginID.uuidString) has no engine instance yet")
            }
            let external = (info["external"] as? NSNumber)?.boolValue == true
            let loaded = (info["loaded"] as? NSNumber)?.boolValue == true
            payload["external"] = .bool(external)
            payload["loaded"] = .bool(loaded)
            payload["variants"] = .array([])
            payload["linked"] = .int(0)
            // What a stereo signal is folded into for a ONE-input plugin (`MonoFold`): the model's choice
            // (a plugin saved before format 28 has no key and plays `MonoFold.whenUnset`, the sum), whether it
            // was CHOSEN (false = no key), and the engine's two service halves when laid.
            if let plug = vm.hostedPlugin(pluginID, of: host) {
                // Format 31: a pick on the cable that ENTERS the plugin says better than its own key.
                if let pick = vm.enteringCablePick(of: pluginID, on: host) {
                    payload["mono_fold"] = .string(pick.rawValue)
                    payload["mono_fold_chosen"] = .bool(true)
                    payload["mono_fold_from_cable"] = .bool(true)
                } else {
                    payload["mono_fold"] = .string(plug.effectiveMonoFold.rawValue)
                    payload["mono_fold_chosen"] = .bool(plug.monoFold != nil)
                    payload["mono_fold_from_cable"] = .bool(false)
                }
            }
            for key in ["fold_in", "fold_out"] {
                if let f = info[key] as? [String: Any] {
                    payload[key] = .object(["active": .bool((f["active"] as? NSNumber)?.boolValue == true),
                                            "mode": .stringOrNull(f["mode"] as? String)])
                } else {
                    payload[key] = .null
                }
            }
            guard external, loaded else { return .object(payload) }
            payload["inputs"] = .int((info["inputs"] as? NSNumber)?.intValue ?? 0)
            payload["outputs"] = .int((info["outputs"] as? NSNumber)?.intValue ?? 0)
            payload["format"] = .stringOrNull(info["format"] as? String)
            payload["current"] = .stringOrNull(info["current"] as? String)
            if let menu = vm.channelMenuState(pluginID: pluginID, host: host) {
                payload["exact"] = .bool(menu.exact)
                payload["linked"] = .int(menu.linkedCount)
                payload["variants"] = .array(menu.entries.map { e in
                    .object(["id": .string(e.variant.rawValue),
                             "inputs": .int(e.variant.inputs), "outputs": .int(e.variant.outputs),
                             "supported": .bool(e.supported), "current": .bool(e.isCurrent)])
                })
            }
            return .object(payload)
        }

        register("plugin.set_channel_layout",
                 summary: """
                 Puts a plugin's main bus in a variant: `mono` (1 in, 1 out), `mono_stereo` (1 in, 2 out) \
                 or `stereo` (2 in, 2 out). The plugin's state is kept, its sidechain wires are laid again, \
                 and the new width is saved with the plugin (its state carries it) and undone with it. \
                 Applies to EVERY active member of the plugin's link group, or to none (`instances` says \
                 how many changed). One undo step. `bad_params`: unknown variant, a built-in plugin, or a \
                 variant the plugin does not accept (`details.reason`: `not_external`, `bad_variant`, \
                 `unsupported`, `refused`). `invalid_state`: the transport is PLAYING (changing the bus \
                 frees the playback context — stop first, `details.reason` `playing`) or the instance is \
                 still loading (`not_loaded`). Already in that variant: `changed` false, no undo step. \
                 Answers `{ok, changed, instances, variant, inputs, outputs}`.
                 """,
                 params: [ParamSpec("host", "uuid", "Object or stem carrying the plugin."),
                          ParamSpec("plugin", "uuid", "Leaf plugin of the chain."),
                          ParamSpec("variant", "string", "mono | mono_stereo | stereo.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)
            let raw = try p.string("variant")
            guard let variant = ChannelVariant(rawValue: raw) else {
                throw CommandError(code: .bad_params, message: "unknown variant '\(raw)' (mono | mono_stereo | stereo)",
                                   details: .object(["reason": .string("bad_variant")]))
            }
            var instances = 0
            switch vm.setChannelVariant(variant, pluginID: pluginID, host: host) {
            case .applied(let n):
                instances = n
            case .unchanged:
                break
            case .refused(let reason):
                let details = JSONValue.object(["reason": .string(reason)])
                switch reason {
                case "playing":
                    throw CommandError(code: .invalid_state,
                                       message: "playback is running: changing the channels would stop it. Stop the transport first",
                                       details: details)
                case "not_loaded":
                    throw CommandError(code: .invalid_state,
                                       message: "plugin \(pluginID.uuidString) is still loading", details: details)
                case "not_external":
                    throw CommandError(code: .bad_params,
                                       message: "plugin \(pluginID.uuidString) is a built-in plugin: it has no channel layout to choose",
                                       details: details)
                case "unsupported", "refused", "bad_variant":
                    throw CommandError(code: .bad_params,
                                       message: "plugin \(pluginID.uuidString) does not accept '\(raw)'", details: details)
                case "unknown_plugin":
                    throw CommandError(code: .not_found, message: "unknown plugin: \(pluginID.uuidString)", details: details)
                default:
                    throw CommandError(code: .invalid_state, message: "channel layout refused: \(reason)", details: details)
                }
            }
            let info = engine.pluginChannelInfo(pluginID.uuidString, probeVariants: false)
            return .object(["ok": .bool(true), "changed": .bool(instances > 0), "instances": .int(instances),
                            "variant": .string(raw),
                            "inputs": .int((info?["inputs"] as? NSNumber)?.intValue ?? variant.inputs),
                            "outputs": .int((info?["outputs"] as? NSNumber)?.intValue ?? variant.outputs)])
        }

        register("plugin.set_mono_fold",
                 summary: """
                 What a STEREO signal is folded into for a plugin with ONE main input: `left` (the left \
                 channel only), `right`, or `sum` = (L + R) / 2 (the default of a plugin inserted since \
                 format 28). Whichever is chosen, the plugin's output replaces the pair (a 1 → 1 plugin's \
                 mono result goes to both sides, the channel not taken is cut). A plugin saved before \
                 format 28 has no choice (`mono_fold_chosen` false in `plugin.channel_layouts`) and plays \
                 `sum`. Saved with the plugin, carried by copies, undone. \
                 ALIAS of `chain.set_cable` since format 31: for a loaded one-input plugin of an object or a \
                 bus, fed by a cable that is still stereo, the choice is written as a PICK on the cable that \
                 enters it (the plugin's own key is cleared; a manual ⌘-link's peers are not carried, an FX \
                 link's bin is). Anywhere else (a send's mini-chain, a plugin not loaded, a cable already \
                 mono) it writes the plugin's own record as before, to its whole link group and the FX \
                 link's definition, with no audible effect while the plugin is not mono-in or the signal is \
                 mono. One undo step; none when nothing changes. Answers `{ok, changed, instances, fold}`.
                 """,
                 params: [ParamSpec("host", "uuid", "Object or stem carrying the plugin."),
                          ParamSpec("plugin", "uuid", "Leaf plugin of the chain."),
                          ParamSpec("fold", "string", "left | right | sum.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)
            let raw = try p.string("fold")
            guard let fold = MonoFold(rawValue: raw) else {
                throw CommandError(code: .bad_params, message: "unknown fold '\(raw)' (left | right | sum)",
                                   details: .object(["reason": .string("bad_fold")]))
            }
            var instances = 0
            switch vm.setMonoFold(fold, pluginID: pluginID, host: host) {
            case .applied(let n): instances = n
            case .unchanged: break
            case .refused(let reason):
                throw CommandError(code: .bad_params,
                                   message: "plugin \(pluginID.uuidString) takes no fold (\(reason))",
                                   details: .object(["reason": .string(reason)]))
            }
            return .object(["ok": .bool(true), "changed": .bool(instances > 0), "instances": .int(instances),
                            "fold": .string(raw)])
        }

        register("chain.cables",
                 summary: """
                 The CABLES of a host's chain (an object or a stem / the Main; a send's mini-chain has none \
                 and answers an empty list): every cable point of every series, in series order — the root \
                 first, then each branch and each FX bin as met. A cable point `index` i is the wire that \
                 ENTERS the card of visible index i of its series (the last index is the tail). Each \
                 carries `series` (`root`, `voice-<block id>-<n>` or `block-<block id>`), `index`, \
                 `width_in` (the channels arriving there, before the choice written there), `choice` \
                 (`stereo` | `left` | `right` | `sum` — the pick of that cable, else the inherited fold of \
                 the one-input plugin it enters, else stereo), `explicit` (a choice is WRITTEN: a pick, the \
                 file's channel mode or the plugin's own key), `offered` (what a hand may choose; empty on a \
                 mono cable, left / right / sum into a one-input plugin), `pick` (the pick's id or null), \
                 `file_level` (the head of a stereo clip: the choice is the file's own channel mode), \
                 `inert` (a pick on a cable already mono: kept, no effect), `entering` (the plugin id or \
                 null) and `into_one_input`. `engine_mode` appears when the engine holds the pick \
                 (`left` | `right` | `sum`). Reads only.
                 """,
                 params: [ParamSpec("host", "uuid", "Object, stem or the Main.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            guard let infos = vm.cableInfos(host: host) else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            let engineModes = vm.enginePickModes(host: host)
            let rows: [JSONValue] = infos.map { c in
                var row: [String: JSONValue] = [
                    "series": .string(c.location.key), "index": .int(c.point.index),
                    "width_in": .int(c.widthIn), "choice": .string(c.choice.rawValue),
                    "explicit": .bool(c.explicit), "offered": .array(c.offered.map { .string($0.rawValue) }),
                    "pick": .stringOrNull(c.pickID?.uuidString), "file_level": .bool(c.fileLevel),
                    "inert": .bool(c.inert), "entering": .stringOrNull(c.entering?.uuidString),
                    "into_one_input": .bool(c.intoOneInput)]
                if let id = c.pickID, let m = engineModes[id] { row["engine_mode"] = .string(m) }
                return .object(row)
            }
            return .object(["host": .string(host.uuidString), "cables": .array(rows)])
        }

        register("chain.set_cable",
                 summary: """
                 Writes a channel CHOICE on one cable of a host's chain (session format 31): `stereo` takes \
                 the cable's pick away, `left` / `right` / `sum` put one there (a pick already there keeps \
                 its id). `series` names the series (`root` by default; see `chain.cables`), `index` the \
                 cable point. A cable that enters a ONE-input plugin hands that plugin's own fold over to the \
                 pick; the head cable of a stereo audio clip is the file's own channel mode (`channelMode`, \
                 never a pick); a cable inside an ATTACHED FX bin is the bin's (every member follows). \
                 One undo step, none when nothing changes. `bad_params`: unknown choice, series or index, or \
                 a choice the cable does not offer (`details.reason` `bad_choice`, `no_such_series`, \
                 `out_of_range`, `not_offered`: stereo into a one-input plugin). `invalid_state`: a mono \
                 cable has nothing to choose (`mono_cable`), a send's mini-chain takes no choice \
                 (`send_chain`). Answers `{ok, changed, instances, choice}`.
                 """,
                 params: [ParamSpec("host", "uuid", "Object, stem or the Main."),
                          ParamSpec("series", "string", required: false,
                                    "`root` (default), `voice-<block id>-<n>` or `block-<block id>`."),
                          ParamSpec("index", "int", "The cable point: the wire entering the card of visible index i."),
                          ParamSpec("choice", "string", "stereo | left | right | sum.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let rawSeries = try p.string("series", or: "root")
            let index = try p.int("index")
            let rawChoice = try p.string("choice")
            guard let choice = CableChoice(rawValue: rawChoice) else {
                throw CommandError(code: .bad_params, message: "unknown choice '\(rawChoice)' (stereo | left | right | sum)",
                                   details: .object(["reason": .string("bad_choice")]))
            }
            guard let location = SeriesLocation(key: rawSeries) else {
                throw CommandError(code: .bad_params, message: "unknown series '\(rawSeries)'",
                                   details: .object(["reason": .string("no_such_series")]))
            }
            var instances = 0
            switch vm.setCableChannels(host: host, location: location, index: index, choice: choice) {
            case .applied(let n): instances = n
            case .unchanged: break
            case .refused(let reason):
                let details = JSONValue.object(["reason": .string(reason)])
                switch reason {
                case "not_found":
                    throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)", details: details)
                case "mono_cable":
                    throw CommandError(code: .invalid_state, message: "the cable is mono: nothing to choose", details: details)
                case "send_chain":
                    throw CommandError(code: .invalid_state,
                                       message: "a send's mini-chain takes no channel choice", details: details)
                default:
                    throw CommandError(code: .bad_params, message: "cable choice refused: \(reason)", details: details)
                }
            }
            return .object(["ok": .bool(true), "changed": .bool(instances > 0), "instances": .int(instances),
                            "choice": .string(rawChoice)])
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
            // A send's mini-chain: plain plugins only (no instrument, no ARA source), its own limit.
            try CommandAdapters.requireRoomOnSend(adding: 1, to: host,
                                                  instrument: available.isInstrument || available.isARA, in: vm)
            // An ARA plugin (Melodyne VST3) is not a chain insert: on an audio object it becomes the
            // clip's SOURCE (`slot: "ara_source"`), and a host that cannot take one refuses.
            if available.isARA {
                guard vm.find(id: host) != nil else {
                    throw CommandError(code: .invalid_state,
                                       message: "'\(available.name)' is an ARA plugin: it can only be the source of an audio object",
                                       details: .object(["reason": .string(ARARefusal.notAClip.rawValue)]))
                }
                if let refusal = vm.setARASource(objectID: host, available: available) {
                    throw CommandError(code: .invalid_state, message: refusal.reason,
                                       details: .object(["reason": .string(refusal.rawValue)]))
                }
                guard let source = vm.find(id: host)?.araSource else {
                    throw CommandError(code: .engine_error, message: "the ARA source vanished after being set")
                }
                return .object(["host": .string(host.uuidString),
                                "slot": .string("ara_source"),
                                "plugin": CommandAdapters.araSourcePayload(source, objectID: host, in: vm)])
            }
            vm.addPlugin(objectID: host, available: available)
            let after = vm.chainPlugins(host) ?? []
            // `addPlugin` removes the entry if the engine cannot instantiate it: not checking
            // would have a command return "ok" while it laid nothing down.
            // `last(where:)`: a send's marker can sit at the end of the array (an append lands behind it).
            guard after.count > before.count, let added = after.last(where: { !$0.isChainMarker }) else {
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
            // The ARA source has its own removal (the model slot and the engine's source, one undo point).
            if vm.find(id: host)?.araSource?.plugin.id == pluginID {
                vm.removeARASource(objectID: host)
                return .object(["host": .string(host.uuidString), "slot": .string("ara_source"),
                                "remaining": .int((vm.chainPlugins(host) ?? []).count)])
            }
            try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)
            vm.removePlugin(objectID: host, pluginID: pluginID)
            return .object(["host": .string(host.uuidString),
                            "remaining": .int((vm.chainPlugins(host) ?? []).count)])
        }

        register("plugin.toggle",
                 summary: "Enables or bypasses a plugin (a toggle, without recompiling the chain). "
                        + "Refused on a gain stage (`invalid_state`, reason `gain_stage_no_bypass`).",
                 params: [ParamSpec("host", "uuid", "Carrying object or stem."),
                          ParamSpec("plugin", "uuid", "Target plugin.")],
                 // `.handled` since 15 September 2026: the method pushes its own point now, and
                 // the bus wrapping it a second time would cost two ⌘Z for one bypass.
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            let plugin = try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)
            if plugin.isGainStage { throw CommandAdapters.gainStageNoBypass(pluginID) }
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
            try CommandAdapters.requireRoomOnSend(adding: (from == to) ? 0 : ids.count, to: to, in: vm)
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
            try CommandAdapters.requireRoomOnSend(adding: (from == to) ? 0 : ids.count, to: to, in: vm)
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
            try CommandAdapters.refuseLinkOnSend([from, to], in: vm)
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

        // A parallel branch, as the signal view makes it (§B.2): from a '+' (`series` + `at`, the drag
        // down-right) or from a card's menu (`plugin`). The CURRENT card selection of this host decides the
        // run, exactly as for the hand (@see SynopticBranchRun): select first with `plugin.select`.
        register("plugin.branch",
                 summary: "Creates a parallel branch in a host's chain, as the signal view does: from the '+' "
                        + "at `at` of `series` (a drag down-right) or from the card `plugin` (its menu). The "
                        + "host's current card selection extends it to the selected run (a '+': the element "
                        + "under it and the selected ones that follow; a card: the selected run round it). "
                        + "An empty series gets an EMPTY branch. One undo point.",
                 params: [ParamSpec("host", "uuid", "Object or stem carrying the chain."),
                          ParamSpec("plugin", "uuid", required: false,
                                    "The card whose menu is used. Excludes 'series' / 'at'."),
                          ParamSpec("series", "string|object", required: false,
                                    "The '+''s series: \"root\" (default) or {\"voice\": <parallel block id>, "
                                  + "\"index\": <branch>}. A bin's series refuses (no branch inside a bin)."),
                          ParamSpec("at", "int", required: false,
                                    "The '+''s index in that series, markers not counted (default: the tail '+').")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            guard let chain = vm.chainPlugins(host) else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            let selection = vm.selectedPluginHostID == host ? vm.selectedPluginIDs : []
            let made: [UUID]?
            if p.raw["plugin"] != nil {
                if p.raw["series"] != nil || p.raw["at"] != nil {
                    throw CommandError(code: .bad_params, message: "'plugin' excludes 'series' and 'at'")
                }
                let id = try p.uuid("plugin")
                guard EditViewModel.locate(id, in: chain) != nil else {
                    throw CommandError(code: .not_found, message: "no such card on this host: \(id.uuidString)")
                }
                made = vm.synopticBranch(objectID: host, pluginID: id, selection: selection)
            } else {
                var raw = p.raw
                if raw["series"] == nil { raw["series"] = .string("root") }
                let q = CommandParams(raw)
                guard case .series(let location, let index) = try CommandAdapters.dropSite(q, chain: chain) else {
                    throw CommandError(code: .bad_params, message: "series: \"root\" or {\"voice\": id, \"index\": n}")
                }
                made = vm.synopticBranch(objectID: host, location: location, at: index, selection: selection)
            }
            guard let made else {
                throw CommandError(code: .invalid_state,
                                   message: "refused: a bin's instance or series is never branched on its own")
            }
            // The block the branch was made in: the carrier holding the first entry of the run (a block that
            // received one more branch is that block itself).
            let after = vm.chainPlugins(host) ?? []
            var block: UUID? = nil
            if let first = made.first {
                if made.count == 1, let e = EditViewModel.findEntry(first, in: after), e.isRack { block = first }
                else if case .voice(let b, _)? = EditViewModel.locate(first, in: after)?.0 { block = b }
            }
            return .object(["host": .string(host.uuidString),
                            "branched": .array(made.map { .string($0.uuidString) }),
                            "empty_branch": .bool(made.isEmpty),
                            "block": block.map { .string($0.uuidString) } ?? .null,
                            "plugins": .array(after.map { CommandAdapters.pluginPayload($0) })])
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
                        + "if a single one is still on, they all go off. ONE undo step. Gain stages "
                        + "have no bypass: they are passed over (`invalid_state`, reason "
                        + "`gain_stage_no_bypass`, when only stages are selected).",
                 params: [], undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            // Only gain stages selected: nothing can be bypassed (they have no bypass).
            let picked = vm.orderedSelectedPlugins()
            if !picked.isEmpty, picked.allSatisfy(\.isGainStage) {
                throw CommandAdapters.gainStageNoBypass(picked[0].id)
            }
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
            if let host = vm.selectedPluginHostID {
                try CommandAdapters.requireRoomOnSend(adding: vm.selectedPluginIDs.count, to: host, in: vm)
            }
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
            try CommandAdapters.requireRoomOnSend(adding: vm.pluginClipboard.count, to: host, in: vm)
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
                 summary: "Writes a parameter of a live instance (by index). On a gain stage "
                        + "(0 gain dB, 1 pan, 2 mute) the write takes one undo point.",
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
            // A GAIN STAGE's parameters are the hand's (its card): one undo point per write, as the
            // card's drag takes one (@see EditViewModel.setGainStage). Any other plugin: unchanged.
            let isStage = vm.gainStageEntry(pluginID) != nil
            if isStage { vm.pushUndo() }
            vm.setPluginParam(pluginID: pluginID, index: index, value: value)
            // A stage's value is mirrored into the model, which the drawn waveform reads (@see
            // EditViewModel.mirrorGainStageValues) — as the card's write does.
            if isStage, let v = vm.gainStageValues(pluginID) { vm.mirrorGainStageValues(pluginID, v) }
            return .object(["plugin": .string(pluginID.uuidString),
                            "index": .int(index),
                            "value": .number(Double(value))])
        }

        register("plugin.meter",
                 summary: """
                 Registers (or, with `plugins` omitted/empty, withdraws) the plugins a VIEW wants metered: what \
                 the open synoptic does on its own. Nothing is measured for a plugin nobody registered (its \
                 `plugin.level` reads 0). `owner` names the registrant (default "api"); the engine measures \
                 the UNION of every owner's list. The plugins are measured at their OUTPUT (RMS), with no \
                 node added to the graph.
                 """,
                 params: [ParamSpec("host", "uuid", "Carrying object, stem, Main or send mini-chain."),
                          ParamSpec("plugins", "array<uuid>", required: false,
                                    "Plugin ids to meter; omitted or [] = withdraw this owner."),
                          ParamSpec("owner", "string", required: false, "Registrant name (default \"api\").")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            guard vm.chainPlugins(host) != nil || vm.find(id: host) != nil else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            let owner = (try p.optionalString("owner")) ?? "api"
            var ids: [UUID] = []
            if let raw = p.raw["plugins"]?.arrayValue {
                for v in raw {
                    guard let s = v.stringValue, let u = UUID(uuidString: s) else {
                        throw CommandError(code: .bad_params, message: "plugins: an array of uuids expected")
                    }
                    ids.append(u)
                }
            }
            vm.setMeteredPlugins(owner: owner, objectID: host, ids: ids)
            return .object(["host": .string(host.uuidString), "owner": .string(owner),
                            "plugins": .array(ids.map { .string($0.uuidString) })])
        }

        register("plugin.level",
                 summary: """
                 The instantaneous OUTPUT level of a plugin (RMS, the synoptic's VU), read only. `level` is the \
                 0..1 value the card draws, mapped from -60..+6 dBFS (`VUScale`; 0 dBFS is not the end of the bar) (`db` is that value \
                 turned back into dB; -60 means silence or floor). 0 when the plugin is not registered \
                 (`plugin.meter`), is bypassed/disabled, or the transport is stopped; an export in progress \
                 never feeds it. A read EMPTIES the engine's peak-hold: the answer is the maximum since the \
                 previous read (two reads within 15 ms return the same value).
                 """,
                 params: [ParamSpec("host", "uuid", "Carrying object, stem, Main or send mini-chain."),
                          ParamSpec("plugin", "uuid", "Target plugin (or the host's instrument).")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            guard let chain = vm.chainPlugins(host) else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            let isInstrument = vm.find(id: host)?.instruments.contains { $0.id == pluginID } ?? false
            guard isInstrument || EditViewModel.flattenLeaves(chain).contains(where: { $0.id == pluginID }) else {
                throw CommandError(code: .not_found, message: "unknown plugin: \(pluginID.uuidString)")
            }
            let level = vm.pluginAudioLevel(objectID: host, pluginID: pluginID)
            return .object(["plugin": .string(pluginID.uuidString),
                            "level": .number(level),
                            "db": .number(VUScale.dB(level))])
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

        register("debug.fxlink_create_empty",
                 summary: """
                 DEBUG. The door of the plugin browser's "New FX link": a bin with NO plugin, its block laid \
                 on `host` at `index` of the main chain (end by default), or inside `block` (an FX link's \
                 block — refused: a bin does not hold a bin). ONE undo point. Answers the link (as \
                 `fxlink.get`). Not a product command: it exists so a scenario can drive the exact function \
                 the hand calls.
                 """,
                 params: [ParamSpec("host", "uuid", "Carrying object or stem."),
                          ParamSpec("index", "int", required: false, "Place in the main chain (default: end)."),
                          ParamSpec("block", "uuid", required: false, "An FX link block of the host: aim INSIDE it (refused).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            guard let chain = vm.chainPlugins(host) else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            let place: (SeriesLocation, Int)
            if let b = try p.optionalUUID("block") { place = (.block(blockID: b), 0) }
            else { place = (.root, try p.optionalInt("index") ?? chain.count) }
            guard let id = vm.createEmptyFXLink(on: host, at: place), let link = vm.fxLink(id) else {
                throw CommandError(code: .invalid_state, message: "no empty FX link could be made there")
            }
            return .object(["id": .string(link.id.uuidString), "name": .string(link.name)])
        }

        register("debug.bridge_report",
                 summary: """
                 DEBUG. The audio bridge as the engine built it, plus the model's plan. `engine` (null if no \
                 build yet): `build` {id, passes, converged, sample_rate, block_size, gate_edges, \
                 gate_refused}, `taps` [{tap, source, rank, age, cached_age, ring_capacity, ring_generation, \
                 latest_end, runs}], `readers` [{plugin, dest_instance, tap, consumer, rank, l_ref, declared, \
                 source_age, delay, status, alignment_error_samples, blocks_read, blocks_uncovered, \
                 blocks_torn}]. `model`: the plan — `refused` ({plugin: reason}), `root_ranks`, `aux_ranks`, \
                 `inner_ranks`, `stem_ranks`, `taps`, `send_routes` (the sends laid), `send_refused`; `sends_path` is always \"bridge\" (kept for scripts). The static numbers say what the graph BELIEVES; what the \
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
                "taps": ranks(plan.taps),
                // The sends the last sync laid (alive, accepted AND confirmed by the engine), and the
                // alive ones the plan refused.
                "send_routes": .array(vm.bridgeLaidSends.sorted { $0.sender.uuidString + $0.aux.uuidString < $1.sender.uuidString + $1.aux.uuidString }
                    .map { .object(["sender": .string($0.sender.uuidString), "aux": .string($0.aux.uuidString)]) }),
                "send_refused": .object(Dictionary(uniqueKeysWithValues: vm.sendRouteStatus.map {
                    ("\($0.key.sender.uuidString)|\($0.key.aux.uuidString)", JSONValue.string($0.value.rawValue)) }))])
            let report = JSONValue.fromFoundation(engine.bridgeReport())
            return .object(["engine": report, "model": model, "sends_path": .string("bridge")])
        }

        register("debug.send_target_menu",
                 summary: """
                 DEBUG. The data of the signal view's "Send to..." menu for one sender, as the view-model \
                 hands it to the pure builder: `sections` [{tier, title_key, entries [{aux, name, enabled, \
                 reason}]}] in the order of Q-U3 (same group, rest of the stem, the Main), the refused and \
                 the already-used auxes greyed with their reason. `retargeting` = the aux of the card whose \
                 target is being changed (left out). Reads only.
                 """,
                 params: [ParamSpec("id", "uuid", "Sending object."),
                          ParamSpec("retargeting", "uuid", required: false, "The aux of the card being re-aimed.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            let retarget = p.raw["retargeting"] != nil ? try p.uuid("retargeting") : nil
            let sections = vm.sendTargetSections(for: id, retargeting: retarget)
            return .object(["sections": .array(sections.map { sec in
                .object(["tier": .number(Double(sec.tier)), "title_key": .string(sec.titleKey),
                         "entries": .array(sec.entries.map { e in
                             .object(["aux": .string(e.id.uuidString), "name": .string(e.name),
                                      "enabled": .bool(e.isEnabled),
                                      "reason": e.disabledReason.map { .string($0) } ?? .null])
                         })])
            })])
        }

        register("debug.route_pick",
                 summary: """
                 DEBUG. Drives the timeline's "choose an object" mode (`RoutePick`) without a screen: \
                 `action` = `begin_send` (id = the sender, position/index as in send.create; `retargeting` = \
                 an aux whose send is re-aimed), `refusal` (object = the candidate: answers the sentence the \
                 veil would say, or null), `commit` (object = the clicked object: the click's path), `end` \
                 (Esc), `state`. Answers the mode (`mode`: none | sidechain | send). The sidechain strip's own \
                 pick is armed by the strip; `state` and `end` see it too.
                 """,
                 params: [ParamSpec("action", "string", "begin_send | refusal | commit | end | state."),
                          ParamSpec("id", "uuid", required: false, "begin_send: the sending object."),
                          ParamSpec("position", "string", required: false, "begin_send: input | chain | pre_fader | post_fader."),
                          ParamSpec("index", "int", required: false, "begin_send, chain: before the top-level plugin i."),
                          ParamSpec("retargeting", "uuid", required: false, "begin_send: the aux whose send is re-aimed."),
                          ParamSpec("object", "uuid", required: false, "refusal / commit: the object under the cursor.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            @MainActor func mode() -> JSONValue {
                switch vm.routePick {
                case .none: return .string("none")
                case .sidechain?: return .string("sidechain")
                case .send?: return .string("send")
                }
            }
            switch try p.string("action") {
            case "begin_send":
                let id = try p.uuid("id")
                guard let obj = vm.find(id: id), !obj.isAux else {
                    throw CommandError(code: .invalid_state, message: "not a sender: \(id.uuidString)")
                }
                let position = try CommandAdapters.parseSendPosition(p, on: obj, fallback: .postFader)
                let retarget = p.raw["retargeting"] != nil ? try p.uuid("retargeting") : nil
                vm.routePick = nil
                vm.beginSendPick(sender: id, position: position, retargeting: retarget)
                return .object(["mode": mode()])
            case "refusal":
                let obj = try p.uuid("object")
                return .object(["mode": mode(), "refusal": vm.routePickRefusalText(for: obj).map { .string($0) } ?? .null])
            case "commit":
                let obj = try p.uuid("object")
                let done = vm.commitRoutePick(objectID: obj)
                return .object(["committed": .bool(done), "mode": mode()])
            case "end":
                vm.endRoutePick()
                return .object(["mode": mode()])
            case "state":
                return .object(["mode": mode()])
            default:
                throw CommandError(code: .bad_params, message: "unknown action")
            }
        }

        register("debug.send_marker_audit",
                 summary: """
                 DEBUG. The audit of send markers (docs/plan_sends_rework.md, INC 2): reads the model and \
                 answers `violations` [{host, path, rule}] — `orphan` (a marker with no send), `duplicate` \
                 (two markers for one aux), `nested` (inside a parallel block or a bin), `on_aux`, `on_stem`, \
                 `in_instruments`, and `phantom` (an entry with no plugin identity that is neither a block \
                 nor a marker: what a marker becomes when a copy rebuilds it as a plugin) — AND the engine's half: \
                 for every sender whose sends are laid, `index_after_*` / `index_before_*` / `tap_position` \
                 when the send plugin sits elsewhere in the list than the model asks (`engine_senders_checked` \
                 says how many senders were judged; call it after `wait_idle`) — plus `markers` \
                 (how many, top level) and `ok`. The scenario asserts `ok` after every phase. Reads only.
                 """,
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            var violations = SendMarkerAudit.violations(items: vm.items, stems: vm.stems)
            // The engine's half: for every sender with a send plugin, where it sits in the list against
            // where the model asks. Run after `wait_idle` (the bridge sync is coalesced).
            var engineChecked = 0
            var layouts: [String: JSONValue] = [:]
            if let engine = try? CommandContext.shared.requireEngine() {
                @MainActor func visit(_ array: [SoundObject]) {
                    for o in array {
                        if o.sends.contains(where: { s in vm.bridgeLaidSends.contains(SendKey(sender: o.id, aux: s.auxID)) }),
                           let raw = engine.chainLayout(forObjectID: o.id.uuidString) as? [[String: Any]] {
                            let layout = raw.compactMap { d -> SendMarkerAudit.LayoutEntry? in
                                guard let i = d["index"] as? Int, let role = d["role"] as? String else { return nil }
                                return SendMarkerAudit.LayoutEntry(index: i, role: role, key: d["key"] as? String,
                                                                   aux: d["aux"] as? String, tapPosition: d["tap_position"] as? Int,
                                                                   chainPlugins: d["chain_plugins"] as? Int,
                                                                   segmentStart: d["segment_start"] as? Bool ?? false,
                                                                   segmentEnd: d["segment_end"] as? Bool ?? false)
                            }
                            engineChecked += 1
                            layouts[o.id.uuidString] = JSONValue.fromFoundation(raw)
                            violations += SendMarkerAudit.engineViolations(object: o, layout: layout)
                        }
                        if case .group(let children, _) = o.kind { visit(children) }
                    }
                }
                visit(vm.items)
            }
            return .object([
                "engine_senders_checked": .int(engineChecked),
                // Each checked sender's list as roles, in order — what a scenario reads to assert an index.
                "engine_layouts": .object(layouts),
                "ok": .bool(violations.isEmpty),
                "markers": .int(SendMarkerAudit.markerCount(items: vm.items)),
                // INC 3: how many plugins the sends carry, and those of them that hold a link
                // membership — always empty (a send's plugin is never linked; each is a violation too).
                "send_plugins": .int(vm.items.reduce(0) { n, o in n + o.sends.reduce(0) { $0 + $1.plugins.count } }),
                "linked_send_plugins": .array(violations.filter { $0.rule == "send_plugin_linked" }
                    .map { .string("\($0.host.uuidString):\($0.path)") }),
                "violations": .array(violations.map {
                    .object(["host": .string($0.host.uuidString), "path": .string($0.path), "rule": .string($0.rule)])
                })])
        }

        register("debug.engine_chain",
                 summary: """
                 DEBUG. The engine's REAL chain of a host (object, stem or Main), nested, as the compile laid it: \
                 `chain` = [{index, role, type, enabled, instance, key?, mode?, branches?}] in list order. \
                 `role` is fader, windowFade, send, `pick` (a channel choice written on a cable: `mode` left / \
                 right / sum), `fold_in` / `fold_out` (the halves of a one-input plugin's fold, `mode` \
                 left / right / sum), fx (any plugin with a model key), gain (a branch's end gain), parallel (its `branches` are lists of the same shape), \
                 channel_mode (the audio file's own choice) or other. What a scenario reads to prove WHERE the \
                 compile put a pick against the plugin it feeds. Reads only; call it after `wait_idle`.
                 """,
                 params: [ParamSpec("id", "uuid", "The host: an object, a stem or the Main.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let id = try p.uuid("id")
            guard let raw = engine.engineChain(forObjectID: vm.engineHostKey(id).uuidString) else {
                throw CommandError(code: .not_found, message: "no engine chain for \(id.uuidString)")
            }
            return .object(["chain": JSONValue.fromFoundation(raw)])
        }

        register("debug.add_test_plugin",
                 summary: """
                 DEBUG. Adds a MEASURING plugin to a host's chain through the normal model path: \
                 `objKeyProbe` (its output left = the direct signal, its right = the sidechain key, so an \
                 export shows whether the key is aligned), `latencyTester` (declares and applies a delay, \
                 `latency_ms`), `gainTester` (a fixed gain, `gain_db`: the identifiable plugin of the \
                 send-position proof) or `clipTester` (a hard clip at `ceiling_db`: a NON-LINEAR plugin, \
                 which tells "before the level" from "after it"). The host may be a send's mini-chain \
                 (`chain_host` of `send.list`). Answers `{plugin}`.
                 """,
                 params: [ParamSpec("host", "uuid", "Receiving object, stem or send chain host."),
                          ParamSpec("type", "string", "`objKeyProbe`, `latencyTester`, `gainTester` or `clipTester`."),
                          ParamSpec("latency_ms", "number", required: false, "latencyTester only: the delay."),
                          ParamSpec("gain_db", "number", required: false, "gainTester only: the gain, in dB."),
                          ParamSpec("ceiling_db", "number", required: false, "clipTester only: the ceiling, in dBFS.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let host = try p.uuid("host")
            let type = try p.string("type")
            guard ["objKeyProbe", "latencyTester", "gainTester", "clipTester"].contains(type) else {
                throw CommandError(code: .bad_params, message: "type must be objKeyProbe, latencyTester, gainTester or clipTester")
            }
            guard let before = vm.chainPlugins(host) else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            try CommandAdapters.requireRoomOnSend(adding: 1, to: host, in: vm)
            // A TracktionInternal identifier is resolved by type name (resolvedPluginTreeForInfo:).
            let available = AvailablePlugin(name: type, manufacturer: "Tracktion", identifier: type,
                                            formatName: "TracktionInternal")
            vm.addPlugin(objectID: host, available: available)
            guard let added = vm.chainPlugins(host).flatMap({ $0.count > before.count ? $0.last(where: { !$0.isChainMarker }) : nil }) else {
                throw CommandError(code: .engine_error, message: "the engine could not instantiate '\(type)'")
            }
            if type == "latencyTester", let ms = try p.optionalDouble("latency_ms") {
                _ = engine.debugSetPluginProperty("time", value: ms / 1000.0, forPlugin: added.id.uuidString)
            }
            if type == "gainTester", let db = try p.optionalDouble("gain_db") {
                _ = engine.debugSetPluginProperty("gainDb", value: db, forPlugin: added.id.uuidString)
            }
            if type == "clipTester", let db = try p.optionalDouble("ceiling_db") {
                _ = engine.debugSetPluginProperty("ceilingDb", value: db, forPlugin: added.id.uuidString)
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

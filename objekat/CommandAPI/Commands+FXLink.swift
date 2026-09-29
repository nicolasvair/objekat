import Foundation

// MARK: - FX links (bins of shared plugins)

/// The `fxlink.*` family. An FX link is a NAMED bin of plugins that several hosts (objects or buses)
/// share: each host keeps its own engine instances, mirrored through the link machinery, and the bin
/// carries their order, on/off and an output section (volume, pan, mute). The model, its rules and
/// the reasons for them are at the head of `SoundObject/FXLink.swift`.
///
/// Two kinds of id, and telling them apart is this family's whole trap:
///  • the DEFINITION plugin's id (`plugins[].id` of a link) — what `add_plugin` returns and
///    `remove_plugin` / `move_plugin` / `set_plugin_enabled` take;
///  • the INSTANCE's id (`members[].instances[].id`) — an ordinary plugin of one host, the id
///    `plugin.set_param`, `plugin.get_params` and the automation address. `instances[].definition`
///    names the definition plugin it mirrors.
///
/// A host's block is named by `block` (its id in the host's chain) or, for convenience, by `link`
/// (the bin it belongs to — a host holds at most one block per bin through this door).
/// Undo policy `.handled` throughout: every mutator pushes its own single point.
extension CommandRegistry {

    // MARK: Payloads

    private func fxLinkJSON(_ link: FXLink, in vm: EditViewModel) -> JSONValue {
        let members = vm.fxLinkMembers(link.id)
        return .object([
            "id": .string(link.id.uuidString),
            "name": .string(link.name),
            "color_index": .int(link.colorIndex),
            "enabled": .bool(link.isEnabled),
            "gain_db": .number(Double(link.gainDb)),
            "pan": .number(Double(link.pan)),
            "muted": .bool(link.muted),
            "plugins": .array(link.plugins.map { d in
                .object(["id": .string(d.id.uuidString),
                         "name": .string(d.name),
                         "manufacturer": .string(d.manufacturer),
                         "identifier": .string(d.identifier),
                         "format": .string(d.formatName),
                         "enabled": .bool(d.isEnabled)])
            }),
            "members": .array(members.map { m in
                let fb = m.block.fxBlock
                var o: [String: JSONValue] = [
                    "host": .string(m.hostID.uuidString),
                    "is_stem": .bool(vm.isStemHost(m.hostID)),
                    "block": .string(m.block.id.uuidString),
                    "detached": .bool(fb?.isDetached ?? false),
                    "instances": .array((fb?.plugins ?? []).map { inst in
                        .object(["id": .string(inst.id.uuidString),
                                 "definition": (inst.effectiveLinkGroupID.map { .string($0.uuidString) }) ?? .null,
                                 "name": .string(inst.name),
                                 "enabled": .bool(inst.isEnabled)])
                    }),
                ]
                if fb?.isDetached == true, let l = fb?.local {
                    o["local"] = .object(["enabled": .bool(l.isEnabled), "gain_db": .number(Double(l.gainDb)),
                                          "pan": .number(Double(l.pan)), "muted": .bool(l.muted)])
                }
                return .object(o)
            }),
        ])
    }

    private func requireFXLink(_ p: CommandParams, _ key: String = "link",
                               in vm: EditViewModel) throws -> FXLink {
        let id = try p.uuid(key)
        guard let link = vm.fxLink(id) else {
            throw CommandError(code: .not_found, message: "unknown FX link: \(id.uuidString)")
        }
        return link
    }

    /// The host's block, named by `block` or by `link`.
    private func requireBlock(_ p: CommandParams, on hostID: UUID,
                              in vm: EditViewModel) throws -> ObjectPlugin {
        guard let chain = vm.chainPlugins(hostID) else {
            throw CommandError(code: .not_found, message: "unknown host: \(hostID.uuidString)")
        }
        let blocks = EditViewModel.fxBlocks(in: chain)
        if let blockID = try p.optionalUUID("block") {
            guard let b = blocks.first(where: { $0.id == blockID }) else {
                throw CommandError(code: .not_found, message: "unknown block: \(blockID.uuidString)")
            }
            return b
        }
        let linkID = try p.uuid("link")
        guard let b = blocks.first(where: { $0.fxBlock?.linkID == linkID }) else {
            throw CommandError(code: .not_found,
                               message: "host \(hostID.uuidString) holds no block of link \(linkID.uuidString)")
        }
        return b
    }

    private func refused(_ what: String) -> CommandError {
        CommandError(code: .invalid_state, message: what)
    }

    func registerFXLinkCommands() {

        register("fxlink.list",
                 summary: "Every FX link of the project: definition, output section and members.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            return .object(["links": .array(vm.fxLinks.map { self.fxLinkJSON($0, in: vm) }),
                            "count": .int(vm.fxLinks.count)])
        }

        register("fxlink.get",
                 summary: "One FX link: definition, output section and members.",
                 params: [ParamSpec("link", "uuid", "The link.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            return self.fxLinkJSON(try self.requireFXLink(p, in: vm), in: vm)
        }

        register("fxlink.create",
                 summary: "Creates an FX link. With `host` + `plugins`: those plugins of one host's "
                        + "chain become the bin's definition and the host's own instances its block. "
                        + "With `objects`: the first of them (timeline order) that has plugins gives "
                        + "the definition (the first run of plain plugins of its chain) and the "
                        + "others receive a block of it at the end of their chain.",
                 params: [ParamSpec("host", "uuid", required: false, "Carrying object or stem."),
                          ParamSpec("plugins", "array<uuid>", required: false,
                                    "Plain plugins of that chain, in ONE series, with no manual link."),
                          ParamSpec("objects", "array<uuid>", required: false,
                                    "Alternative to host+plugins: several timeline objects."),
                          ParamSpec("name", "string", required: false, "Name (default 'FX link N').")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let name = try p.optionalString("name")
            let linkID: UUID?
            if p.raw["objects"] != nil {
                linkID = vm.createFXLinkFromObjects(try p.uuids("objects"), name: name)
            } else {
                let host = try p.uuid("host")
                guard vm.chainPlugins(host) != nil else {
                    throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
                }
                linkID = vm.createFXLink(from: host, pluginIDs: try p.uuids("plugins"), name: name)
            }
            guard let linkID, let link = vm.fxLink(linkID) else {
                throw self.refused("no FX link could be made of that (plugins must be plain, in one "
                                 + "series, free of any manual link and not already in a bin)")
            }
            return self.fxLinkJSON(link, in: vm)
        }

        register("fxlink.delete",
                 summary: "Dissolves an FX link: every member keeps its plugins, inline and independent "
                        + "(the bin's volume/pan/mute are not carried over; a bypass is).",
                 params: [ParamSpec("link", "uuid", "The link.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let link = try self.requireFXLink(p, in: vm)
            vm.deleteFXLink(link.id)
            return .object(["deleted": .string(link.id.uuidString)])
        }

        register("fxlink.rename",
                 summary: "Renames an FX link.",
                 params: [ParamSpec("link", "uuid", "The link."), ParamSpec("name", "string", "New name.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let link = try self.requireFXLink(p, in: vm)
            vm.renameFXLink(link.id, to: try p.string("name"))
            return self.fxLinkJSON(vm.fxLink(link.id) ?? link, in: vm)
        }

        register("fxlink.set_color",
                 summary: "Sets the colour of an FX link (an index into the plugin palette).",
                 params: [ParamSpec("link", "uuid", "The link."),
                          ParamSpec("color_index", "int", "Palette index.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let link = try self.requireFXLink(p, in: vm)
            let i = try p.int("color_index")
            guard i >= 0 && i < ObjekatPalette.plugins.count else {
                throw CommandError(code: .bad_params, message: "color_index out of range")
            }
            vm.setFXLinkColor(link.id, colorIndex: i)
            return self.fxLinkJSON(vm.fxLink(link.id) ?? link, in: vm)
        }

        register("fxlink.add_plugin",
                 summary: "Adds a plugin to the bin's definition: every attached member gets an "
                        + "instance. Either from the catalogue (identifier/name/format, like plugin.add) "
                        + "or as a COPY of a plugin of some host (`from_host` + `from_plugin`, its live "
                        + "state included; the source is left as it is). Answers the DEFINITION id.",
                 params: [ParamSpec("link", "uuid", "The link."),
                          ParamSpec("identifier", "string", required: false, "Exact catalogue identifier."),
                          ParamSpec("name", "string", required: false, "Failing an identifier: a name."),
                          ParamSpec("format", "string", required: false, "Format to settle ties."),
                          ParamSpec("from_host", "uuid", required: false, "Host of the plugin to copy."),
                          ParamSpec("from_plugin", "uuid", required: false, "The plugin to copy."),
                          ParamSpec("index", "int", required: false, "Place in the definition (default: end).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let link = try self.requireFXLink(p, in: vm)
            let index = try p.optionalInt("index")
            let defID: UUID?
            if p.raw["from_plugin"] != nil {
                let host = try p.uuid("from_host")
                let source = try CommandAdapters.requirePlugin(try p.uuid("from_plugin"), on: host, in: vm)
                defID = vm.fxAddPlugin(linkID: link.id, template: source,
                                       state: vm.fxLiveState(of: source), at: index)
            } else {
                let available = try CommandAdapters.resolvePlugin(p, in: vm)
                let template = ObjectPlugin(id: UUID(), name: available.name,
                                            manufacturer: available.manufacturer,
                                            identifier: available.identifier,
                                            formatName: available.formatName)
                defID = vm.fxAddPlugin(linkID: link.id, template: template, at: index)
            }
            guard let defID else {
                throw CommandError(code: .engine_error, message: "the engine could not instantiate that plugin")
            }
            return .object(["link": self.fxLinkJSON(vm.fxLink(link.id) ?? link, in: vm),
                            "definition": .string(defID.uuidString)])
        }

        register("fxlink.remove_plugin",
                 summary: "Removes a plugin (by DEFINITION id) from the bin: every member loses it.",
                 params: [ParamSpec("link", "uuid", "The link."),
                          ParamSpec("plugin", "uuid", "The definition plugin.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let link = try self.requireFXLink(p, in: vm)
            guard vm.fxRemovePlugin(linkID: link.id, definitionID: try p.uuid("plugin")) else {
                throw CommandError(code: .not_found, message: "unknown definition plugin")
            }
            return self.fxLinkJSON(vm.fxLink(link.id) ?? link, in: vm)
        }

        register("fxlink.move_plugin",
                 summary: "Reorders the bin's definition: every member follows.",
                 params: [ParamSpec("link", "uuid", "The link."),
                          ParamSpec("plugin", "uuid", "The definition plugin."),
                          ParamSpec("index", "int", "Its place once taken out of the list.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let link = try self.requireFXLink(p, in: vm)
            let id = try p.uuid("plugin")
            guard link.plugins.contains(where: { $0.id == id }) else {
                throw CommandError(code: .not_found, message: "unknown definition plugin")
            }
            vm.fxMovePlugin(linkID: link.id, definitionID: id, to: try p.int("index"))
            return self.fxLinkJSON(vm.fxLink(link.id) ?? link, in: vm)
        }

        register("fxlink.set_plugin_enabled",
                 summary: "Enables or bypasses ONE plugin of the bin (by definition id), for every member.",
                 params: [ParamSpec("link", "uuid", "The link."),
                          ParamSpec("plugin", "uuid", "The definition plugin."),
                          ParamSpec("enabled", "bool", "On or off.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let link = try self.requireFXLink(p, in: vm)
            let id = try p.uuid("plugin")
            guard link.plugins.contains(where: { $0.id == id }) else {
                throw CommandError(code: .not_found, message: "unknown definition plugin")
            }
            vm.fxSetPluginEnabled(linkID: link.id, definitionID: id, enabled: try p.bool("enabled"))
            return self.fxLinkJSON(vm.fxLink(link.id) ?? link, in: vm)
        }

        register("fxlink.set_enabled",
                 summary: "The bin's COMMON on/off: off bypasses every attached member's block, its "
                        + "output section included.",
                 params: [ParamSpec("link", "uuid", "The link."), ParamSpec("enabled", "bool", "On or off.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let link = try self.requireFXLink(p, in: vm)
            vm.fxSetEnabled(linkID: link.id, enabled: try p.bool("enabled"))
            return self.fxLinkJSON(vm.fxLink(link.id) ?? link, in: vm)
        }

        register("fxlink.set_output",
                 summary: "The bin's output section — an end-of-series gain stage on every attached "
                        + "member: volume (dB), pan (-1…1) and mute. Omitted fields are left as they are.",
                 params: [ParamSpec("link", "uuid", "The link."),
                          ParamSpec("gain_db", "number", required: false, "Volume, -96…+40 dB."),
                          ParamSpec("pan", "number", required: false, "Pan, -1…+1."),
                          ParamSpec("muted", "bool", required: false, "Mute.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let link = try self.requireFXLink(p, in: vm)
            vm.fxSetOutput(linkID: link.id,
                           gainDb: try p.optionalDouble("gain_db").map { Float($0) },
                           pan: try p.optionalDouble("pan").map { Float($0) },
                           muted: p.raw["muted"] == nil ? nil : try p.bool("muted"))
            return self.fxLinkJSON(vm.fxLink(link.id) ?? link, in: vm)
        }

        register("fxlink.attach",
                 summary: "Gives a host (object or bus) a block of the bin, at the end of its chain "
                        + "(or at `index`). A host holding a DETACHED block of it gets it reattached.",
                 params: [ParamSpec("link", "uuid", "The link."),
                          ParamSpec("host", "uuid", "Receiving object or stem."),
                          ParamSpec("index", "int", required: false, "Place in the host's chain (default: end).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let link = try self.requireFXLink(p, in: vm)
            let host = try p.uuid("host")
            guard vm.chainPlugins(host) != nil else {
                throw CommandError(code: .not_found, message: "unknown host: \(host.uuidString)")
            }
            let place = try p.optionalInt("index").map { (SeriesLocation.root, $0) }
            guard let block = vm.attachFXLink(link.id, to: host, at: place) else {
                throw self.refused("the host could not be attached to that link")
            }
            return .object(["block": .string(block.uuidString),
                            "link": self.fxLinkJSON(vm.fxLink(link.id) ?? link, in: vm)])
        }

        register("fxlink.detach",
                 summary: "Takes a host's block out of the bin, in place: the host keeps an INDEPENDENT "
                        + "copy of the chain as it is now, with its own output section.",
                 params: [ParamSpec("host", "uuid", "The host."),
                          ParamSpec("block", "uuid", required: false, "The host's block."),
                          ParamSpec("link", "uuid", required: false, "Or the bin it belongs to.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let block = try self.requireBlock(p, on: host, in: vm)
            guard vm.detachFXBlock(hostID: host, blockID: block.id) else {
                throw self.refused("that block is already detached")
            }
            return .object(["block": .string(block.id.uuidString)])
        }

        register("fxlink.reattach",
                 summary: "Puts a detached block back on its bin: the host realigns on the definition "
                        + "(order, membership, output) and adopts the group's settings.",
                 params: [ParamSpec("host", "uuid", "The host."),
                          ParamSpec("block", "uuid", required: false, "The host's block."),
                          ParamSpec("link", "uuid", required: false, "Or the bin it belongs to.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let block = try self.requireBlock(p, on: host, in: vm)
            guard vm.reattachFXBlock(hostID: host, blockID: block.id) else {
                throw self.refused("that block is not detached")
            }
            return .object(["block": .string(block.id.uuidString)])
        }

        register("fxlink.release",
                 summary: "The host leaves the bin for good and KEEPS its plugins, inline and independent.",
                 params: [ParamSpec("host", "uuid", "The host."),
                          ParamSpec("block", "uuid", required: false, "The host's block."),
                          ParamSpec("link", "uuid", required: false, "Or the bin it belongs to.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let block = try self.requireBlock(p, on: host, in: vm)
            vm.releaseFXBlock(hostID: host, blockID: block.id)
            return .object(["host": .string(host.uuidString),
                            "plugins": .array((vm.chainPlugins(host) ?? []).map(CommandAdapters.pluginPayload))])
        }

        register("fxlink.remove_block",
                 summary: "The host drops the block AND its instances (the bin and the other members stay).",
                 params: [ParamSpec("host", "uuid", "The host."),
                          ParamSpec("block", "uuid", required: false, "The host's block."),
                          ParamSpec("link", "uuid", required: false, "Or the bin it belongs to.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let block = try self.requireBlock(p, on: host, in: vm)
            vm.removeFXBlock(hostID: host, blockID: block.id)
            return .object(["host": .string(host.uuidString)])
        }

        register("fxlink.move_block",
                 summary: "Moves a host's block within its chain (root series): `index` is its place "
                        + "counted BEFORE the move, like the synoptic's drop position.",
                 params: [ParamSpec("host", "uuid", "The host."),
                          ParamSpec("block", "uuid", required: false, "The host's block."),
                          ParamSpec("link", "uuid", required: false, "Or the bin it belongs to."),
                          ParamSpec("index", "int", "Target place in the root chain.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let block = try self.requireBlock(p, on: host, in: vm)
            vm.moveFXBlock(hostID: host, blockID: block.id, to: .root, at: try p.int("index"))
            return .object(["host": .string(host.uuidString),
                            "plugins": .array((vm.chainPlugins(host) ?? []).map(CommandAdapters.pluginPayload))])
        }

        register("fxlink.set_local_output",
                 summary: "The output section of a DETACHED block (its own copy): enabled, volume, pan, mute.",
                 params: [ParamSpec("host", "uuid", "The host."),
                          ParamSpec("block", "uuid", required: false, "The host's block."),
                          ParamSpec("link", "uuid", required: false, "Or the bin it belongs to."),
                          ParamSpec("enabled", "bool", required: false, "Common on/off of the copy."),
                          ParamSpec("gain_db", "number", required: false, "Volume, -96…+40 dB."),
                          ParamSpec("pan", "number", required: false, "Pan, -1…+1."),
                          ParamSpec("muted", "bool", required: false, "Mute.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let block = try self.requireBlock(p, on: host, in: vm)
            guard vm.fxSetLocalOutput(hostID: host, blockID: block.id,
                                      gainDb: try p.optionalDouble("gain_db").map { Float($0) },
                                      pan: try p.optionalDouble("pan").map { Float($0) },
                                      muted: p.raw["muted"] == nil ? nil : try p.bool("muted"),
                                      enabled: p.raw["enabled"] == nil ? nil : try p.bool("enabled"))
            else { throw self.refused("only a detached block has an output section of its own") }
            return .object(["block": .string(block.id.uuidString)])
        }
    }
}

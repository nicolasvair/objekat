import Foundation

// MARK: - Stems (output buses)

/// A stem is a BUS, not a label: it carries a FolderTrack, its FX chain, its gain, its mute and
/// its routing to the Main. Assigning an object to a stem therefore really moves it inside the
/// graph — hence always going through `assignStem`, which propagates to the children and
/// reconciles the sends again (the scope of a send is read off the stem).
extension CommandRegistry {

    func registerStemCommands() {

        register("stem.list",
                 summary: "Every stem: id, name, format, gain, mute, routing, plugins.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let mainID = vm.mainStemID
            let stems = vm.stems.map { stem -> JSONValue in
                .object([
                    "id": .string(stem.id.uuidString),
                    "name": .string(stem.name),
                    // The Main is not a stem like the others: neither mutable nor routable.
                    // Flagging it saves a script from a gesture that would be ignored.
                    "is_main": .bool(stem.id == mainID),
                    "format": .string(stem.format.rawValue),
                    "color_index": .int(stem.colorIndex),
                    "gain_db": .number(Double(stem.gainDb ?? 0)),
                    "muted": .bool(stem.muted),
                    "route_to_main": .bool(stem.routeToMain),
                    "plugin_count": .int(stem.plugins.count),
                ])
            }
            return .object(["stems": .array(stems), "main": .string(mainID.uuidString)])
        }

        register("stem.add",
                 summary: "Creates a stem (an output bus).",
                 params: [ParamSpec("name", "string", "Stem name."),
                          ParamSpec("format", "string", required: false, "mono | stereo (default stereo)."),
                          ParamSpec("color_index", "int", required: false, "Tint 0…15 (default 1).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let name = try p.string("name")
            let rawFormat = try p.string("format", or: "stereo")
            guard let format = StemFormat(rawValue: rawFormat) else {
                throw CommandError(code: .bad_params,
                                   message: "unknown format: '\(rawFormat)' (mono or stereo)")
            }
            let color = try p.int("color_index", or: 1)
            let id = vm.addStem(name: name, colorIndex: color, format: format)
            return .object(["id": .string(id.uuidString), "name": .string(name)])
        }

        register("stem.remove",
                 summary: "Deletes a stem; its objects go back to the Main.",
                 params: [ParamSpec("id", "uuid", "Stem to delete.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try CommandAdapters.existingStem(try p.uuid("id"), in: vm)
            guard id != vm.mainStemID else {
                throw CommandError(code: .invalid_state, message: "the Main cannot be deleted")
            }
            vm.removeStem(id: id)
            return .object(["removed": .string(id.uuidString), "stems": .int(vm.stems.count)])
        }

        register("stem.rename",
                 summary: "Renames a stem.",
                 params: [ParamSpec("id", "uuid", "Target stem."),
                          ParamSpec("name", "string", "New name.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try CommandAdapters.existingStem(try p.uuid("id"), in: vm)
            let name = try p.string("name")
            vm.renameStem(id: id, name: name)
            return .object(["id": .string(id.uuidString),
                            "name": .string(vm.stems.first { $0.id == id }?.name ?? name)])
        }

        register("stem.recolor",
                 summary: "Changes a stem's tint (the same palette as object colours).",
                 params: [ParamSpec("id", "uuid", "Target stem."),
                          ParamSpec("color_index", "int", "Tint 0…15.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try CommandAdapters.existingStem(try p.uuid("id"), in: vm)
            let index = try p.int("color_index")
            vm.recolorStem(id: id, colorIndex: index)
            return .object(["id": .string(id.uuidString), "color_index": .int(index)])
        }

        register("stem.assign",
                 summary: "Assigns objects to a stem (a group's children follow).",
                 params: [ParamSpec("stem", "uuid", "Receiving stem."),
                          ParamSpec("ids", "array<uuid>", required: false,
                                    "Target objects; default = current selection.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let stemID = try CommandAdapters.existingStem(try p.uuid("stem"), in: vm)
            let ids: [UUID]
            if p.raw["ids"] != nil {
                ids = try CommandAdapters.existingIDs(try p.uuids("ids"), in: vm)
            } else {
                ids = Array(vm.effectiveSelectedIDs)
            }
            guard !ids.isEmpty else {
                throw CommandError(code: .invalid_state, message: "no target object")
            }
            for id in ids { vm.assignStem(objectID: id, stemID: stemID) }
            return .object(["stem": .string(stemID.uuidString), "count": .int(ids.count)])
        }

        register("stem.set_gain",
                 summary: "Sets the gain of a stem's bus (dB).",
                 params: [ParamSpec("id", "uuid", "Target stem."),
                          ParamSpec("db", "number", "Gain, in dB.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try CommandAdapters.existingStem(try p.uuid("id"), in: vm)
            let db = Float(try p.double("db"))
            vm.setStemGain(id, dB: db)
            return .object(["id": .string(id.uuidString),
                            "gain_db": .number(Double(vm.stemGainDb(id)))])
        }

        register("stem.mute",
                 summary: "Mutes or unmutes a stem's bus (without touching the objects' own mute).",
                 params: [ParamSpec("id", "uuid", "Target stem."),
                          ParamSpec("muted", "bool", required: false, "Wanted state; absent = toggle.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try CommandAdapters.existingStem(try p.uuid("id"), in: vm)
            guard let current = vm.stems.first(where: { $0.id == id }) else {
                throw CommandError(code: .not_found, message: "unknown stem: \(id.uuidString)")
            }
            let wanted = try p.bool("muted", or: !current.muted)
            if current.muted != wanted { vm.toggleStemMute(id) }
            return .object(["id": .string(id.uuidString),
                            "muted": .bool(vm.stems.first { $0.id == id }?.muted ?? false)])
        }

        register("stem.route_to_main",
                 summary: "Sums (or not) the stem's bus into the main mix.",
                 params: [ParamSpec("id", "uuid", "Target stem."),
                          ParamSpec("on", "bool", "true = summed into the Main.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try CommandAdapters.existingStem(try p.uuid("id"), in: vm)
            let on = try p.bool("on")
            vm.setStemRouteToMain(id, on: on)
            return .object(["id": .string(id.uuidString),
                            "route_to_main": .bool(vm.stems.first { $0.id == id }?.routeToMain ?? true)])
        }

        register("stem.level",
                 summary: "Instantaneous audio level of the bus (VU). Read only.",
                 params: [ParamSpec("id", "uuid", required: false,
                                    "Target stem; default = all.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            if let id = try p.optionalUUID("id") {
                let stemID = try CommandAdapters.existingStem(id, in: vm)
                return .object(["id": .string(stemID.uuidString),
                                "level": .number(Double(vm.stemLevel(stemID)))])
            }
            var levels: [String: JSONValue] = [:]
            for stem in vm.stems { levels[stem.id.uuidString] = .number(Double(vm.stemLevel(stem.id))) }
            return .object(["levels": .object(levels)])
        }
    }
}

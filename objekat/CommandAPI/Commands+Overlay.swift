import Foundation

/// The `overlay.*` family — what a script SHOWS over an object, without touching the project.
///
/// Nothing here is an edit: `undo: .none`, the project is not made dirty, the layer is not in the
/// undo snapshot and is never written to the session file. It belongs to the CONNECTION that laid
/// it — closing the connection (or killing the script) removes it — and it goes when the object
/// does (@see EditViewModel+ScriptOverlay). All times are seconds RELATIVE TO THE OBJECT's start.
extension CommandRegistry {

    func registerOverlayCommands() {

        func parseTexts(_ v: JSONValue) throws -> [OverlayText] {
            guard let arr = v.arrayValue else {
                throw CommandError(code: .bad_params, message: "'texts' must be an array")
            }
            return try arr.map { e in
                guard let o = e.objectValue, let s = o["start"]?.doubleValue,
                      let en = o["end"]?.doubleValue, let t = o["text"]?.stringValue else {
                    throw CommandError(code: .bad_params,
                                       message: "a text is {start, end, text}")
                }
                guard s <= en else {
                    throw CommandError(code: .bad_params, message: "a text has start > end")
                }
                return OverlayText(start: s, end: en, text: t)
            }
        }

        func parseZones(_ v: JSONValue) throws -> [OverlayZone] {
            guard let arr = v.arrayValue else {
                throw CommandError(code: .bad_params, message: "'zones' must be an array")
            }
            return try arr.map { e in
                guard let o = e.objectValue, let s = o["start"]?.doubleValue,
                      let en = o["end"]?.doubleValue else {
                    throw CommandError(code: .bad_params,
                                       message: "a zone is {start, end, color?, opacity?}")
                }
                guard s <= en else {
                    throw CommandError(code: .bad_params, message: "a zone has start > end")
                }
                var color = OverlayColor.white
                if let name = o["color"]?.stringValue {
                    guard let c = OverlayColor(rawValue: name) else {
                        throw CommandError(code: .bad_params,
                                           message: "unknown colour '\(name)' (white, red, yellow, green, blue)")
                    }
                    color = c
                }
                let opacity = min(1, max(0, o["opacity"]?.doubleValue ?? 0.3))
                return OverlayZone(start: s, end: en, color: color, opacity: opacity)
            }
        }

        func zonesPayload(_ o: ScriptOverlay) -> JSONValue {
            .array(o.zones.map {
                .object(["start": .number($0.start), "end": .number($0.end),
                         "color": .string($0.color.rawValue), "opacity": .number($0.opacity)])
            })
        }

        register("overlay.set",
                 summary: "Lays words and / or coloured zones over an object — presentation only: no "
                        + "undo, never saved, cleared when the calling connection closes or the "
                        + "object goes. Times are seconds RELATIVE to the object's start. A field "
                        + "that is absent is KEPT; a field that is present replaces that field.",
                 params: [ParamSpec("id", "uuid", "The object."),
                          ParamSpec("texts", "array<{start,end,text}>", required: false,
                                    "Words (a transcription). Sorted by the app."),
                          ParamSpec("zones", "array<{start,end,color?,opacity?}>", required: false,
                                    "Passages. color: white|red|yellow|green|blue (default white); "
                                  + "opacity 0…1 (default 0.3)."),
                          ParamSpec("replace", "array<string>", required: false,
                                    "Fields ('texts' / 'zones') to EMPTY even when no new value "
                                  + "comes with them.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            vm.pruneScriptOverlays()
            let id = try p.uuid("id")
            guard vm.find(id: id) != nil else {
                throw CommandError(code: .not_found, message: "no object \(id.uuidString)")
            }
            let texts = try p.raw["texts"].map(parseTexts)
            let zones = try p.raw["zones"].map(parseZones)
            var clearing = Set<String>()
            if p.raw["replace"] != nil {
                for e in try p.array("replace") {
                    guard let f = e.stringValue, f == "texts" || f == "zones" else {
                        throw CommandError(code: .bad_params,
                                           message: "'replace' names 'texts' and / or 'zones'")
                    }
                    clearing.insert(f)
                }
            }
            let existing = vm.scriptOverlays.overlays[id]
            let nTexts = clearing.contains("texts") || texts != nil ? (texts?.count ?? 0) : (existing?.texts.count ?? 0)
            let nZones = clearing.contains("zones") || zones != nil ? (zones?.count ?? 0) : (existing?.zones.count ?? 0)
            guard nTexts <= ScriptOverlayStore.maxElements, nZones <= ScriptOverlayStore.maxElements else {
                throw CommandError(code: .bad_params,
                                   message: "more than \(ScriptOverlayStore.maxElements) elements")
            }
            let o = vm.scriptOverlays.set(object: id, owner: CommandCallContext.caller,
                                          texts: texts, zones: zones, clearing: clearing)
            return .object(["id": .string(id.uuidString), "texts": .int(o.texts.count),
                            "zones": .int(o.zones.count), "rev": .int(o.rev)])
        }

        register("overlay.clear",
                 summary: "Removes an object's overlay; with no id, every overlay the CALLING "
                        + "connection laid.",
                 params: [ParamSpec("id", "uuid", required: false, "The object.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            if let id = try p.optionalUUID("id") {
                return .object(["cleared": .int(vm.scriptOverlays.clear(object: id) ? 1 : 0)])
            }
            return .object(["cleared": .int(vm.scriptOverlays.clear(owner: CommandCallContext.caller))])
        }

        register("overlay.get",
                 summary: "An object's overlay: the number of words, the zones, and whether the "
                        + "calling connection owns it. `detail: true` also returns the words.",
                 params: [ParamSpec("id", "uuid", "The object."),
                          ParamSpec("detail", "bool", required: false, "Return the words too.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            vm.pruneScriptOverlays()
            let id = try p.uuid("id")
            guard let o = vm.scriptOverlays.overlays[id] else {
                throw CommandError(code: .not_found, message: "no overlay on \(id.uuidString)")
            }
            var out: [String: JSONValue] = [
                "id": .string(id.uuidString), "texts": .int(o.texts.count),
                "zones": zonesPayload(o), "rev": .int(o.rev),
                "owner_is_caller": .bool(o.owner == CommandCallContext.caller)]
            if try p.bool("detail", or: false) {
                out["words"] = .array(o.texts.map {
                    .object(["start": .number($0.start), "end": .number($0.end),
                             "text": .string($0.text)])
                })
            }
            return .object(out)
        }

        register("overlay.list",
                 summary: "Every object that carries an overlay, with its counts.",
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            vm.pruneScriptOverlays()
            let rows = vm.scriptOverlays.overlays.sorted { $0.key.uuidString < $1.key.uuidString }
            return .object(["overlays": .array(rows.map { id, o in
                .object(["id": .string(id.uuidString), "texts": .int(o.texts.count),
                         "zones": .int(o.zones.count)])
            })])
        }
    }
}

import Foundation

// MARK: - The timeline's tools (`tool.*`)

/// Arms and reads the active tool — the door a script has onto what ⇧ + a tool key does by hand.
///
/// A held key (C, V, P, A, a digit) arms its tool for as long as it is down and gives the
/// selection tool back on release; with ⇧ the tool is LOCKED instead, and stays until another tool
/// or Esc replaces it. A script holds no key, so the only form it can ask for is the locked one:
/// `tool.set` writes exactly what the ⇧ branches of `TimelineKeyHandler` write
/// (`activeTool`, `isToolPermanent = true`, `heldToolKeyCode = nil`), and the tool palette's
/// buttons write the same three. "Releasing" the tool is `tool.set {tool: "selection"}`.
///
/// It exists for the performance harness first: under the Volume / Pan / Aux tool every block
/// of the timeline keeps its rich SwiftUI view, and nothing headless could put the timeline in
/// that state (@see `perf.census.regimes.rich_reasons`, `tools/bench_groups.py`).
///
/// Undo policy `.none`: a tool is session state, outside `items`, outside the undo, never saved.
extension CommandRegistry {

    /// The names a script uses, in the order the palette shows them.
    private static let toolNames: [(name: String, tool: ActiveTool)] = [
        ("selection", .toolSelection), ("cut", .toolCut), ("volume", .toolVolume),
        ("pan", .toolPan), ("aux", .toolAux), ("stem", .toolStemAssign),
        ("fx", .toolFX),
    ]

    /// The script's name for a tool (`view.state.hover` reports it too).
    static func toolName(_ tool: ActiveTool) -> String {
        toolNames.first { $0.tool == tool }?.name ?? "selection"
    }

    private func toolJSON(_ vm: EditViewModel) -> JSONValue {
        let name = Self.toolName(vm.activeTool)
        let stemIndex = vm.activeTool == .toolStemAssign ? vm.stemAssignIndex : nil
        let stemName = stemIndex.flatMap { $0 >= 1 && $0 <= vm.stems.count ? vm.stems[$0 - 1].name : nil }
        return .object([
            "tool": .string(name),
            "locked": .bool(vm.isToolPermanent),
            // A key still down (a real one: a script cannot hold any) — the tool is temporary.
            "held_by_key": .bool(vm.heldToolKeyCode != nil),
            "stem": stemIndex.map { JSONValue.int($0) } ?? JSONValue.null,
            "stem_name": .stringOrNull(stemName),
        ])
    }

    func registerToolCommands() {

        register("tool.get",
                 summary: "The active tool: selection | cut | volume | pan | aux | stem | fx, whether it is "
                        + "locked (armed as ⇧ + the key arms it) or held by a key, and for the stem "
                        + "tool its target (a 1-based index: 1 = Main, 2 = the 2nd stem…).") { _ in
            self.toolJSON(try CommandContext.shared.requireViewModel())
        }

        register("tool.set",
                 summary: "Arms a tool, LOCKED, exactly as ⇧ + its key does (a script holds no key): "
                        + "selection (E) | cut (C) | volume (V) | pan (P) | aux (A) | fx (F) | stem (a digit). "
                        + "It stays armed until another tool.set — `selection` is how the tool is "
                        + "'released' — or Esc. Session state: no undo point, never saved.",
                 params: [ParamSpec("tool", "string", "selection | cut | volume | pan | aux | fx | stem."),
                          ParamSpec("stem", "int", required: false,
                                    "With `stem`: the target, a 1-based index (1 = Main, 2 = the 2nd "
                                  + "stem…). Default 1.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let name = try p.string("tool")
            guard let entry = Self.toolNames.first(where: { $0.name == name }) else {
                throw CommandError(code: .bad_params,
                                   message: "'tool': expected one of "
                                          + Self.toolNames.map(\.name).joined(separator: ", "))
            }
            if entry.tool == .toolStemAssign {
                let n = try p.int("stem", or: 1)
                guard n >= 1, n <= vm.stems.count else {
                    throw CommandError(code: .bad_params,
                                       message: "'stem': 1…\(vm.stems.count) (1 = Main)")
                }
                vm.stemAssignIndex = n
            } else if p.raw["stem"] != nil {
                throw CommandError(code: .bad_params, message: "'stem' only goes with the stem tool")
            }
            // What the ⇧ branches of TimelineKeyHandler (and the palette's buttons) write.
            vm.activeTool = entry.tool
            vm.isToolPermanent = true
            vm.heldToolKeyCode = nil
            return self.toolJSON(vm)
        }

        register("tool.fx_strip",
                 summary: "What the FX tool's strip shows for an object (hovering it under F): "
                        + "`entries` in the order drawn, left to right — {id, kind: instrument | "
                        + "plugin | gain_stage | rack, name, enabled, toggle (has a power button), "
                        + "editor (a double click opens a window), bin (index into `bins`, or null), "
                        + "branches (a rack)} — `bins` [{id, name, detached}] (the FX link blocks, "
                        + "framed), and the strip's `size` {w, h} in points. A read: the strip's "
                        + "power button is `plugin.toggle` / the instrument's toggle, its double "
                        + "click the editor (no window without an interface).",
                 params: [ParamSpec("id", "uuid", "The object.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard vm.find(id: id) != nil else {
                throw CommandError(code: .not_found, message: "no object \(id.uuidString)")
            }
            let m = vm.fxStripModel(objectID: id)
            let size = FXStripLayout.layout(m).size
            return .object([
                "entries": .array(m.entries.map { e in
                    var kind = "plugin"
                    var branches = JSONValue.null
                    switch e.kind {
                    case .instrument: kind = "instrument"
                    case .plugin: kind = "plugin"
                    case .gainStage: kind = "gain_stage"
                    case .rack(let n): kind = "rack"; branches = .int(n)
                    }
                    return .object([
                        "id": .string(e.id.uuidString), "kind": .string(kind), "name": .string(e.name),
                        "enabled": .bool(e.isEnabled), "toggle": .bool(e.hasToggle),
                        "editor": .bool(e.opensEditor),
                        "bin": e.bin.map { JSONValue.int($0) } ?? .null, "branches": branches,
                    ])
                }),
                "bins": .array(m.bins.map { b in
                    .object(["id": .string(b.id.uuidString), "name": .string(b.name),
                             "detached": .bool(b.isDetached)])
                }),
                "size": .object(["w": .number(Double(size.width)), "h": .number(Double(size.height))]),
            ])
        }
    }
}

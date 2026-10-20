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
                 summary: "What the FX tool's mini signal view shows for an object (hovering it under "
                        + "F, drawn INSIDE its block): `entries` — {id, kind: instrument | plugin | "
                        + "gain_stage | rack, name, enabled, toggle (has a power button), editor (a "
                        + "double click opens a window), bin (index into `bins`, or null), branches "
                        + "(a rack), rack (for a plugin inside a parallel block: the index of its "
                        + "rack's entry, else null), branch (its 0-based branch, else null)} in chain "
                        + "order, a rack's plugins right after it; `tree` — the chain as nested "
                        + "lists: an entry index, or {rack: index, branches: [[…], …]}; `bins` [{id, "
                        + "name, detached}] (the FX link blocks, framed); `size` {w, h}: the smallest "
                        + "room (points) the labeled reading needs. With `w` and `h`: `layout` — how "
                        + "it is drawn in a block area of that size: {detail: labeled | dots | "
                        + "folded_dots | count | empty | none, boxes: [{entry, x, y, w, h, power "
                        + "(has a power zone), folded}], wires (count), bins (frame count)}. A read: "
                        + "the power button is `plugin.toggle` / the instrument's toggle, the double "
                        + "click the editor (no window without an interface).",
                 params: [ParamSpec("id", "uuid", "The object."),
                          ParamSpec("w", "number", required: false, "The area's width, points (with `h`)."),
                          ParamSpec("h", "number", required: false, "The area's height, points (with `w`).")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard vm.find(id: id) != nil else {
                throw CommandError(code: .not_found, message: "no object \(id.uuidString)")
            }
            let m = vm.fxStripModel(objectID: id)
            let size = FXStripLayout.labeledSize(m)
            func node(_ n: FXStripNode) -> JSONValue {
                switch n {
                case .leaf(let i): return .number(Double(i))
                case .rack(let c, let branches):
                    return .object(["rack": .number(Double(c)),
                                    "branches": .array(branches.map { .array($0.map(node)) })])
                }
            }
            var out: [String: JSONValue] = [
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
                        "rack": e.rack.map { JSONValue.int($0) } ?? .null,
                        "branch": e.branch.map { JSONValue.int($0) } ?? .null,
                    ])
                }),
                "tree": .array(m.root.map(node)),
                "bins": .array(m.bins.map { b in
                    .object(["id": .string(b.id.uuidString), "name": .string(b.name),
                             "detached": .bool(b.isDetached)])
                }),
                "size": .object(["w": .number(Double(size.width)), "h": .number(Double(size.height))]),
            ]
            if let w = try p.optionalDouble("w"), let h = try p.optionalDouble("h") {
                let lay = FXStripLayout.layout(m, in: CGRect(x: 0, y: 0, width: w, height: h))
                let detail: String
                switch lay.detail {
                case .labeled: detail = "labeled"
                case .dots: detail = "dots"
                case .foldedDots: detail = "folded_dots"
                case .count: detail = "count"
                case .empty: detail = "empty"
                case .none: detail = "none"
                }
                out["layout"] = .object([
                    "detail": .string(detail),
                    "boxes": .array(lay.boxes.map { b in
                        .object(["entry": .int(b.entry),
                                 "x": .number(Double(b.rect.minX)), "y": .number(Double(b.rect.minY)),
                                 "w": .number(Double(b.rect.width)), "h": .number(Double(b.rect.height)),
                                 "power": .bool(b.power != nil), "folded": .bool(b.folded)])
                    }),
                    "wires": .int(lay.wires.count),
                    "bins": .int(lay.bins.count),
                ])
            }
            return .object(out)
        }
    }
}

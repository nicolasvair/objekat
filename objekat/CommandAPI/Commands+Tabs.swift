import Foundation

/// The `tab.*` family (tabs INC1) — driving the `Workspace` a script cannot otherwise reach: every
/// other command in this file family keeps acting on the ACTIVE tab exactly as it always has
/// (`CommandContext.viewModel`/`engine` are the session's, hence the active tab's, by
/// construction) — "the context is the active tab" is the whole contract, unchanged by this file.
/// Undo policy `.none` throughout: switching, opening or closing a tab is a WORKSPACE operation,
/// never one `EditSnapshot`/`pushUndo` has anything to say about.
extension CommandRegistry {

    private func requireWorkspace() throws -> Workspace {
        guard let workspace = CommandContext.shared.workspace else {
            throw CommandError(code: .invalid_state, message: "no workspace attached")
        }
        return workspace
    }

    private func tabJSON(_ workspace: Workspace, _ tab: WorkspaceTab, index: Int) -> JSONValue {
        .object([
            "id": .string(tab.id.uuidString),
            "index": .int(index + 1),
            "name": .string(workspace.displayName(for: tab)),
            "path": .stringOrNull(workspace.url(for: tab)?.path),
            "dirty": .bool(workspace.isDirty(for: tab)),
            "active": .bool(tab.id == workspace.activeTabID),
        ])
    }

    /// Resolves `{id}` or `{index}` (1-based, as shown by `tab.list`) to a tab id — the same pair
    /// `tab.select` and `tab.close` both accept, one definition so they never drift about which
    /// index means what.
    private func resolveTabID(_ p: CommandParams, _ workspace: Workspace) throws -> UUID {
        if let idString = try p.optionalString("id") {
            guard let id = UUID(uuidString: idString) else {
                throw CommandError(code: .bad_params, message: "parameter 'id': invalid UUID")
            }
            return id
        }
        if let index = try p.optionalInt("index") {
            guard index >= 1, index <= workspace.tabs.count else {
                throw CommandError(code: .bad_params,
                                   message: "parameter 'index': out of range (1...\(workspace.tabs.count))")
            }
            return workspace.tabs[index - 1].id
        }
        throw CommandError(code: .bad_params, message: "either 'id' or 'index' is required")
    }

    func registerTabCommands() {

        register("tab.list",
                 summary: "Lists the open project tabs, in order.",
                 undo: .none) { _ in
            let workspace = try self.requireWorkspace()
            let items = workspace.tabs.enumerated().map { self.tabJSON(workspace, $1, index: $0) }
            return .object(["tabs": .array(items), "count": .int(items.count)])
        }

        register("tab.new",
                 summary: "Opens a new, empty project in its own tab and makes it active.",
                 undo: .none) { _ in
            let workspace = try self.requireWorkspace()
            switch workspace.newTab() {
            case .success:
                let idx = workspace.tabs.firstIndex { $0.id == workspace.activeTabID }!
                return self.tabJSON(workspace, workspace.tabs[idx], index: idx)
            case .failure(let error):
                throw error.commandError
            }
        }

        register("tab.select",
                 summary: "Brings a tab to the front — by 'id' (from tab.list) or 1-based 'index'.",
                 params: [ParamSpec("id", "string", required: false, "The tab's id."),
                          ParamSpec("index", "int", required: false, "1-based position (tab.list order).")],
                 undo: .none) { p in
            let workspace = try self.requireWorkspace()
            let id = try self.resolveTabID(p, workspace)
            switch await workspace.select(id) {
            case .success:
                let idx = workspace.tabs.firstIndex { $0.id == id }!
                return self.tabJSON(workspace, workspace.tabs[idx], index: idx)
            case .failure(let error):
                throw error.commandError
            }
        }

        register("tab.move",
                 summary: "Moves a tab — by 'id' or 1-based 'index' — to the 1-based position 'to' "
                        + "in the strip. The active tab stays active; only the order changes.",
                 params: [ParamSpec("id", "string", required: false, "The tab's id."),
                          ParamSpec("index", "int", required: false, "1-based position (tab.list order)."),
                          ParamSpec("to", "int", "1-based position the tab ends up at.")],
                 undo: .none) { p in
            let workspace = try self.requireWorkspace()
            let id = try self.resolveTabID(p, workspace)
            let to = try p.int("to")
            guard to >= 1, to <= workspace.tabs.count else {
                throw CommandError(code: .bad_params,
                                   message: "parameter 'to': out of range (1...\(workspace.tabs.count))")
            }
            switch workspace.moveTab(id, to: to - 1) {
            case .success:
                let idx = workspace.tabs.firstIndex { $0.id == id }!
                return self.tabJSON(workspace, workspace.tabs[idx], index: idx)
            case .failure(let error):
                throw error.commandError
            }
        }

        register("tab.close",
                 summary: "Closes a tab (the active one if 'id'/'index' is omitted). The last tab "
                        + "never closes. 'discard' (default false) must be true to close a tab "
                        + "carrying unsaved changes.",
                 params: [ParamSpec("id", "string", required: false, "The tab's id."),
                          ParamSpec("index", "int", required: false, "1-based position (tab.list order)."),
                          ParamSpec("discard", "bool", required: false,
                                    "true = close even if modified (default false).")],
                 undo: .none) { p in
            let workspace = try self.requireWorkspace()
            let id: UUID
            if try p.optionalString("id") != nil || p.raw["index"] != nil {
                id = try self.resolveTabID(p, workspace)
            } else {
                id = workspace.activeTabID
            }
            let discard = try p.bool("discard", or: false)
            switch workspace.close(id, discard: discard) {
            case .success:
                return .object(["ok": .bool(true)])
            case .failure(let error):
                throw error.commandError
            }
        }

        register("tab.open",
                 summary: "Opens a project file in a NEW tab. A file already open in another tab "
                        + "switches to it instead of opening a second copy ('already_open': true).",
                 params: [ParamSpec("path", "string", "Path to the project file.")],
                 undo: .none) { p in
            let workspace = try self.requireWorkspace()
            let path = try p.string("path")
            guard FileManager.default.fileExists(atPath: path) else {
                throw CommandError(code: .not_found, message: "file not found: \(path)")
            }
            let url = URL(fileURLWithPath: path)
            switch await workspace.open(url: url, inNewTab: true) {
            case .success(let outcome):
                let idx = workspace.tabs.firstIndex { $0.id == outcome.tabID }!
                var obj = self.tabJSON(workspace, workspace.tabs[idx], index: idx).objectValue!
                obj["already_open"] = .bool(outcome.alreadyOpen)
                return .object(obj)
            case .failure(let error):
                throw error.commandError
            }
        }
    }
}

extension Workspace.TabError {
    /// One definition for the whole family: every `tab.*` adapter throws the SAME `CommandError`
    /// for the same `Workspace.TabError`, rather than each adapter inventing its own message.
    var commandError: CommandError {
        switch self {
        case .blocked(let reasonKey):
            // English, hard-coded — API messages never follow the interface's language
            // (@see docs/glossary.md): `reasonKey` is the i18n key the UI shows through `L(_:)`,
            // not what a script should read here.
            let message: String
            switch reasonKey {
            case "tabs.switch.refused.loading":
                message = "a project is loading"
            case "tabs.switch.refused.export":
                message = "an export is running"
            case "tabs.switch.refused.render":
                message = "a consolidated object is rendering"
            case "tabs.switch.refused.consolidateEdit":
                message = "a consolidated object is being edited"
            default:
                message = reasonKey
            }
            return CommandError(code: .invalid_state, message: "tab switch refused: \(message)")
        case .dirty:
            return CommandError(code: .invalid_state,
                                message: "tab has unsaved changes — pass discard: true")
        case .lastTab:
            return CommandError(code: .invalid_state, message: "the last tab cannot be closed")
        case .notFound:
            return CommandError(code: .not_found, message: "no such tab")
        case .decodeFailed(let detail):
            return CommandError(code: .invalid_state, message: "could not read the project: \(detail)")
        case .loadFailed:
            return CommandError(code: .invalid_state, message: "could not load the project")
        case .cancelled:
            return CommandError(code: .invalid_state, message: "cancelled")
        }
    }
}

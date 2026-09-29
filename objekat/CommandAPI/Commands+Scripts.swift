import Foundation

/// The `script.*` family — the same door a menu click uses (`ScriptPluginRegistry`), open to a
/// script or a headless test. Without it, the whole third-party-script mechanism — including an
/// 'object'-context entry's `OBJEKAT_OBJECT_IDS` — could only be exercised by a real click in a
/// real menu, which `--headless` has none of (@see plan_separateur_voix.md, T2.5).
extension CommandRegistry {

    func registerScriptCommands() {

        register("script.list",
                 summary: "Lists the installed third-party scripts (manifests read at launch, "
                        + "or since the last 'Reload the scripts').") { _ in
            let plugins = ScriptPluginRegistry.shared.plugins
            return .object(["scripts": .array(plugins.map { plugin in
                .object([
                    "name": .string(plugin.folder.lastPathComponent),
                    "display_name": .string(plugin.displayName),
                    "available": .bool(plugin.isAvailable),
                    "unavailable_reason": .stringOrNull(plugin.unavailableReason),
                    "entries": .array(plugin.entries.map { entry in
                        .object(["title": .string(entry.title),
                                "context": .string(plugin.effectiveContext(for: entry))])
                    }),
                ])
            })])
        }

        register("script.run",
                 summary: "Launches an installed script exactly as a menu click would — the "
                        + "script runs as a SEPARATE PROCESS and this command does not wait for "
                        + "it (@see job.wait for that pattern elsewhere; a script has none of "
                        + "its own). A non-zero exit is reported through 'app.dialogs', not by "
                        + "this call, which only reports a FAILURE TO START.",
                 params: [ParamSpec("script", "string",
                                    "The script's folder name, as 'script.list' names it."),
                          ParamSpec("entry", "string", required: false,
                                    "The menu entry's title; absent = the first entry."),
                          ParamSpec("ids", "array<uuid>", required: false,
                                    "Object ids handed to the script as OBJEKAT_OBJECT_IDS "
                                  + "(an 'object'-context entry only).")],
                 undo: .none) { p in
            let name = try p.string("script")
            guard let plugin = ScriptPluginRegistry.shared.plugin(named: name) else {
                throw CommandError(code: .not_found, message: "unknown script '\(name)'")
            }
            let entryTitle = try p.optionalString("entry")
            guard let entry = ScriptPluginRegistry.shared.entry(named: entryTitle, in: plugin) else {
                throw CommandError(code: .not_found, message: "unknown entry '\(entryTitle ?? "")'")
            }
            let ids: [UUID] = p.raw["ids"] != nil ? try p.uuids("ids") : []
            if let error = ScriptPluginRegistry.shared.run(plugin, entry: entry, objectIDs: ids) {
                throw CommandError(code: .invalid_state, message: error)
            }
            return .object(["started": .bool(true)])
        }
    }
}

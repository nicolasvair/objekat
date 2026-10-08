import Foundation

// MARK: - The report for a language model: how to fix a file's duplicated plugin ids by hand
//
// "Copy report" (the alert that opens a file carrying duplicated plugin ids) puts this text on the
// pasteboard, and `project.load_status` returns it, so the file can be corrected ELSEWHERE — by an
// assistant that edits the JSON — instead of in the app. It is a contract for a machine, like the
// session file's own `_readme` and the command API: ENGLISH, never through `L()`, and the same on
// every machine, so that it can be asserted word for word (`tools/test_plugin_id_uniqueness.swift`).
// Only the names the user typed (objects, plugins, bins, stems) are not ours; everything else is
// plain ASCII, which is also why it survives any pasteboard or chat box.
//
// PURE: no `L()`, no AppKit, no date — the same arguments give the same text. The JSON paths come
// from `PluginIDUniqueness.duplicateDetails`, which writes them from the real array indexes and
// Codable keys of the file the app itself produced.

enum PluginIDReport {

    /// The instructions. `filePath` is the manifest the duplicates were read from (absolute, as the
    /// app opened it); `details` come from `PluginIDUniqueness.duplicateDetails`, in file order — the
    /// first site of each is the entry that KEEPS its id, the others are the ones to fix.
    static func text(filePath: String, details: [PluginIDUniqueness.DuplicateDetail]) -> String {
        let entries = details.reduce(0) { $0 + $1.sites.count }
        let copies = entries - details.count   // every site after the first of its id

        var out: [String] = []
        out.append("OBJEKAT - duplicated plugin ids: repair instructions")
        out.append("====================================================")
        out.append("")
        out.append("File: \(clean(filePath))")
        out.append("")
        out.append("RULE. Every \"id\" in this file must be unique in the whole project. A plugin's id is the key of")
        out.append("ONE live instance in the audio engine: when two entries carry the same id, only one of them gets")
        out.append("the plugin and the others play dry. This file breaks the rule \(copies) time(s): \(details.count) plugin id(s),")
        out.append("carried by \(entries) entries in all.")
        out.append("")
        out.append("DUPLICATED IDS (in file order; the entry marked KEEP is the first occurrence)")
        out.append("")
        for (n, d) in details.enumerated() {
            let name = d.sites.first?.pluginName ?? ""
            out.append("\(n + 1). id \(d.id.uuidString)  -  plugin \"\(clean(name))\"")
            for (i, s) in d.sites.enumerated() {
                let tag = i == 0 ? "KEEP" : "FIX "
                let kind = s.hostKind == .stem ? "stem" : "object"
                var line = "   \(tag)  \(kind) \"\(clean(s.hostName))\" (\(s.hostID.uuidString))"
                if let link = s.fxLinkName { line += ", fx link \"\(clean(link))\"" }
                out.append(line)
                out.append("         path: \(s.jsonPath)")
            }
        }
        out.append("")
        out.append("HOW TO FIX (touch nothing else)")
        out.append("1. Quit OBJEKAT, or at least close this project, BEFORE editing: the app rewrites the file when it")
        out.append("   saves, and would put the duplicates back.")
        out.append("2. Keep a backup copy of the file.")
        out.append("3. For every entry marked FIX: replace its \"id\" with a NEW random UUID (uppercase, like the others,")
        out.append("   one new UUID per entry, never reused).")
        out.append("4. In the SAME object as that entry (the object that owns the FIX path; a stem has no automation),")
        out.append("   replace the old id with the new one wherever it appears as \"pluginKey\": in")
        out.append("   automation[].param.pluginKey and in automationTouch[].pluginKey. Do not touch the automation")
        out.append("   of any other object.")
        out.append("5. Do NOT change anything else: not linkGroupID, detachedLinkGroupID, fxBlock.linkID, stateXML,")
        out.append("   names, colours, the fxLinks registry, nor the entries marked KEEP. Keep the JSON valid and the")
        out.append("   \"_readme\" key as it is.")
        out.append("6. Reopen the project in OBJEKAT: it must open with no warning about duplicated plugins.")
        out.append("")
        out.append("The paths above are JSON paths from the root of the file (items[i].kind.children[j] descends into")
        out.append("a group; .plugins / .instruments are chains; .araSource.plugin is an ARA source; .rack.voices[v] and .fxBlock.plugins hold nested")
        out.append("plugins).")
        return out.joined(separator: "\n") + "\n"
    }

    /// A name or a path on one line: a typed name can hold a newline or a control character, which
    /// would break the layout the instructions rely on.
    private static func clean(_ s: String) -> String {
        String(s.map { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 } ?? false) ? " " : $0 })
    }
}

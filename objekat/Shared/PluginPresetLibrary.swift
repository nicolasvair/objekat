import Foundation

// MARK: - The presets OBJEKAT keeps for a plugin, beside the plugin's own

/// What a plugin TYPE is, for the preset library: its format and its identifier — the pair
/// `plugin.add` uses, and the only one two instances of the same plugin always share (the name is
/// not enough: an AU and a VST3 of one product share it, and their states are not interchangeable).
nonisolated struct PluginPresetKey: Hashable, Sendable {
    let formatName: String
    let identifier: String
}

/// One preset: a name and the plugin's FULL state as Tracktion serialises it (`getPluginStateXML`:
/// the built-in parameters, or an external plugin's binary chunk) — exactly what `ObjectPlugin.stateXML`
/// holds, so loading one is the same operation as an undo putting a state back.
nonisolated struct PluginPreset: Codable, Equatable, Sendable {
    var format: Int = 1
    var name: String
    var identifier: String
    var formatName: String
    var pluginName: String
    var stateXML: String
}

/// The library on disk: one FOLDER per plugin type, holding one `.objpreset` (JSON) per preset and a
/// `plugin.json` naming the type and its DEFAULT preset (the one laid on a plugin freshly inserted).
///
///     <root>/<format> - <plugin name> - <hash>/plugin.json
///     <root>/<format> - <plugin name> - <hash>/<preset name>.objpreset
///
/// The folder name carries a hash of the identifier because two products can share a name and an
/// identifier is not a file name (AU identifiers hold `/` and `:`); the readable part is there for a
/// person browsing the Finder. Nothing here touches the engine or the model: it is a file store,
/// testable on its own (`tools/test_plugin_preset_library.swift`).
///
/// Where it lives: `~/Library/Application Support/Objekat/Presets`, or `--preset-library=PATH`, or —
/// under `--no-recent` / `--headless` with no explicit path — a folder of the process's own in the
/// temporary directory: a test never writes into the user's library (the "Recent projects" rule).
nonisolated final class PluginPresetLibrary: @unchecked Sendable {

    let root: URL

    init(root: URL) { self.root = root }

    /// The library this process uses (@see the type's comment for the three cases).
    static let shared: PluginPresetLibrary = {
        let a = LaunchArguments.process
        if let path = a.value("preset-library") {
            return PluginPresetLibrary(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                                                 isDirectory: true))
        }
        if a.noRecentProjects || a.headless {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("objekat-presets-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
            return PluginPresetLibrary(root: tmp)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return PluginPresetLibrary(root: support.appendingPathComponent("Objekat/Presets", isDirectory: true))
    }()

    static let fileExtension = "objpreset"
    private static let indexName = "plugin.json"

    enum LibraryError: Error, Equatable {
        case emptyName
        case notFound(String)
        case io(String)
    }

    private struct Index: Codable {
        var identifier: String
        var formatName: String
        var pluginName: String
        var defaultPreset: String?
    }

    // MARK: Names

    /// A preset name as typed, trimmed. Empty → nil (refused).
    static func normalisedName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// A file-system safe rendering of a name: no `/`, `:`, control characters or leading dot, at most
    /// 100 characters. Two names that collapse onto the same file name are the same preset (the
    /// comparison below is case-insensitive like the default APFS volume).
    static func fileStem(_ name: String) -> String {
        var s = ""
        for u in name.unicodeScalars {
            if u == "/" || u == ":" || u == "\\" || CharacterSet.controlCharacters.contains(u) { s.append("_") }
            else { s.unicodeScalars.append(u) }
        }
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 100 { s = String(s.prefix(100)) }
        return s.isEmpty ? "_" : s
    }

    /// FNV-1a 64 of the identifier, 8 hex digits — stable across runs and machines (`hashValue` is not).
    static func shortHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%08llx", h & 0xffffffff)
    }

    func folder(for key: PluginPresetKey, pluginName: String) -> URL {
        // An existing folder for this key wins whatever its readable part (the plugin may have been
        // renamed since): the hash is what identifies it.
        if let existing = existingFolder(for: key) { return existing }
        let readable = Self.fileStem("\(key.formatName) - \(pluginName)")
        return root.appendingPathComponent(readable + " - " + Self.shortHash(key.formatName + "|" + key.identifier),
                                           isDirectory: true)
    }

    private func existingFolder(for key: PluginPresetKey) -> URL? {
        let suffix = " - " + Self.shortHash(key.formatName + "|" + key.identifier)
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasSuffix(suffix) })
    }

    // MARK: Reading

    /// Every preset of this plugin type, sorted by name (case and diacritics folded, then raw: a total
    /// order, so a menu never reshuffles).
    func presets(for key: PluginPresetKey) -> [PluginPreset] {
        guard let dir = existingFolder(for: key),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        let all = files.filter { $0.pathExtension == Self.fileExtension }.compactMap { url -> PluginPreset? in
            guard let data = try? Data(contentsOf: url),
                  let p = try? decoder.decode(PluginPreset.self, from: data),
                  p.identifier == key.identifier, p.formatName == key.formatName else { return nil }
            return p
        }
        return all.sorted {
            let a = $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let b = $1.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return a == b ? $0.name < $1.name : a < b
        }
    }

    func preset(named name: String, for key: PluginPresetKey) -> PluginPreset? {
        let stem = Self.fileStem(name).lowercased()
        return presets(for: key).first { Self.fileStem($0.name).lowercased() == stem }
    }

    /// The name of this type's default preset, if it still exists.
    func defaultPresetName(for key: PluginPresetKey) -> String? {
        guard let dir = existingFolder(for: key),
              let data = try? Data(contentsOf: dir.appendingPathComponent(Self.indexName)),
              let idx = try? JSONDecoder().decode(Index.self, from: data),
              let name = idx.defaultPreset, preset(named: name, for: key) != nil else { return nil }
        return name
    }

    /// The state to lay on a plugin of this type freshly inserted, nil = none.
    func defaultState(for key: PluginPresetKey) -> String? {
        defaultPresetName(for: key).flatMap { preset(named: $0, for: key)?.stateXML }
    }

    // MARK: Writing

    /// Writes (or overwrites) a preset. Returns the stored preset.
    @discardableResult
    func save(name rawName: String, stateXML: String, key: PluginPresetKey, pluginName: String) throws -> PluginPreset {
        guard let name = Self.normalisedName(rawName) else { throw LibraryError.emptyName }
        let dir = folder(for: key, pluginName: pluginName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // A name that collapses onto an existing file replaces that file (and takes its spelling).
            if let old = preset(named: name, for: key) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.fileStem(old.name) + "." + Self.fileExtension))
            }
            let p = PluginPreset(name: name, identifier: key.identifier, formatName: key.formatName,
                                 pluginName: pluginName, stateXML: stateXML)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(p).write(to: dir.appendingPathComponent(Self.fileStem(name) + "." + Self.fileExtension),
                                    options: .atomic)
            try writeIndex(dir: dir, key: key, pluginName: pluginName, defaultPreset: readDefaultRaw(dir))
            return p
        } catch let e as LibraryError { throw e }
        catch { throw LibraryError.io(error.localizedDescription) }
    }

    func delete(name: String, key: PluginPresetKey) throws {
        guard let dir = existingFolder(for: key), let p = preset(named: name, for: key) else {
            throw LibraryError.notFound(name)
        }
        do {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(Self.fileStem(p.name) + "." + Self.fileExtension))
            // The default goes with its preset.
            if let d = readDefaultRaw(dir), Self.fileStem(d).lowercased() == Self.fileStem(p.name).lowercased() {
                try writeIndex(dir: dir, key: key, pluginName: p.pluginName, defaultPreset: nil)
            }
        } catch { throw LibraryError.io(error.localizedDescription) }
    }

    /// Names (or clears, with nil) this type's default preset. The preset must exist.
    func setDefault(name: String?, key: PluginPresetKey, pluginName: String) throws {
        if let name, preset(named: name, for: key) == nil { throw LibraryError.notFound(name) }
        let stored = name.flatMap { preset(named: $0, for: key)?.name }
        if stored == nil, existingFolder(for: key) == nil { return }   // nothing to clear
        let dir = folder(for: key, pluginName: pluginName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeIndex(dir: dir, key: key, pluginName: pluginName, defaultPreset: stored)
        } catch { throw LibraryError.io(error.localizedDescription) }
    }

    private func readDefaultRaw(_ dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.indexName)),
              let idx = try? JSONDecoder().decode(Index.self, from: data) else { return nil }
        return idx.defaultPreset
    }

    private func writeIndex(dir: URL, key: PluginPresetKey, pluginName: String, defaultPreset: String?) throws {
        let idx = Index(identifier: key.identifier, formatName: key.formatName,
                        pluginName: pluginName, defaultPreset: defaultPreset)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(idx).write(to: dir.appendingPathComponent(Self.indexName), options: .atomic)
    }
}

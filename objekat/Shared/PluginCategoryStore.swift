import Foundation
import Perception

// MARK: - The colour category of each plugin (plugin browser)

/// The hand's own sorting of the plugin catalogue: the colour categories of each plugin — SEVERAL
/// if the hand says so ("uncategorised" = no entry at all). It is the APP's memory, not the project's
/// — a plugin is the same plugin whatever the session — kept in `UserDefaults` under a single key, a
/// flat dictionary `"<format>|<identifier>" → [palette index]` (an entry written when a plugin had
/// ONE category is a bare index, and is still read).
///
/// The store also remembers the other things the browser keeps from one opening to the next:
/// the ORDER the hand gave the colour tabs (`categoryOrder`), the NAME the hand gave a colour
/// (`categoryNames`: a colour is nameless until it is told — empty = no name) and which external
/// formats are shown (`showsAU`, `showsVST3`).
///
/// The key is `formatName + "|" + identifier`: NEVER `AvailablePlugin.id`, a UUID regenerated at
/// every parse of the scan (@see SynopticModelMapping — the same pair identifies a plugin there).
///
/// An entry whose plugin is no longer installed is KEPT: a plugin that comes back after an
/// uninstall, or a catalogue that is still being scanned, must find its colour again.
///
/// A test never touches the real domain: under `--no-recent` or `--headless` the entries live in a
/// dictionary that dies with the process (same discretion as `ScriptPanelMemory`). The behaviour is
/// identical, so a scenario can still assert it.
@Perceptible
final class PluginCategoryStore {

    /// The one store of the app.
    static let shared = PluginCategoryStore()

    static let defaultsKey = "pluginBrowser.categories"

    static var processIsEphemeral: Bool {
        let a = LaunchArguments.process
        return a.noRecentProjects || a.headless
    }

    /// The stable identity of a plugin in the store (and in `PluginBrowserModel`).
    static func key(format: String, identifier: String) -> String {
        format + "|" + normalizedIdentifier(format: format, identifier: identifier)
    }

    /// The scan writes an AudioUnit as "aufx,SpMd,oDin"; once the plugin has been INSTANTIATED the
    /// known list also holds JUCE's own spelling of it, "AudioUnit:Effects/aufx,SpMd,oDin". One
    /// plugin, two descriptions: what follows the last "/" is the same in both.
    static func normalizedIdentifier(format: String, identifier: String) -> String {
        guard format == "AudioUnit", let slash = identifier.lastIndex(of: "/") else { return identifier }
        return String(identifier[identifier.index(after: slash)...])
    }

    static let categoryOrderKey = "pluginBrowser.categoryOrder"
    /// `"<palette index>" → name` (a dictionary property list has string keys only).
    static let categoryNamesKey = "pluginBrowser.categoryNames"
    /// The longest a category's name is kept (what a tab's tooltip and a palette chip can say).
    static let maxNameLength = 40
    static let showsAUKey = "pluginBrowser.showsAU"
    static let showsVST3Key = "pluginBrowser.showsVST3"

    /// The ephemeral world, one dictionary per defaults key, shared by every store of the process.
    nonisolated(unsafe) private static var ephemeral: [String: [String: [Int]]] = [:]
    nonisolated(unsafe) private static var ephemeralAdded: [String: [Int]] = [:]
    nonisolated(unsafe) private static var ephemeralNames: [String: [Int: String]] = [:]
    nonisolated(unsafe) private static var ephemeralFormats: [String: [Bool]] = [:]

    /// Test door: forgets what the ephemeral world holds for `key`.
    static func resetEphemeral(for key: String = defaultsKey) {
        ephemeral.removeValue(forKey: key)
        ephemeralAdded.removeValue(forKey: key)
        ephemeralNames.removeValue(forKey: key)
        ephemeralFormats.removeValue(forKey: key)
    }

    /// `key → palette indices` (ascending, distinct, never empty). Read it to draw; write it through
    /// `toggle` / `set`.
    private(set) var entries: [String: [Int]]

    /// The colour tabs' order as the hand left it (@see PluginCategoryPalette.ordered). A colour
    /// that is not in it comes after those that are.
    private(set) var categoryOrder: [Int]

    /// The names the hand gave to colours: `palette index → name`, never empty, trimmed, at most
    /// `maxNameLength` long. A colour with no entry has no name (@see `setCategoryName`).
    private(set) var categoryNames: [Int: String]

    /// Which external formats the browser lists. Never both false (@see `setShows`).
    private(set) var showsAU: Bool
    private(set) var showsVST3: Bool

    /// How many times the storage was written: a change of nothing must write nothing.
    @PerceptionIgnored private(set) var writeCount = 0

    @PerceptionIgnored private let defaults: UserDefaults
    @PerceptionIgnored private let storageKey: String
    @PerceptionIgnored private let isEphemeral: Bool

    init(defaults: UserDefaults = .standard,
         storageKey: String = PluginCategoryStore.defaultsKey,
         ephemeral: Bool = PluginCategoryStore.processIsEphemeral) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.isEphemeral = ephemeral
        if ephemeral {
            self.entries = Self.ephemeral[storageKey] ?? [:]
            self.categoryOrder = Self.ephemeralAdded[storageKey] ?? []
            self.categoryNames = Self.ephemeralNames[storageKey] ?? [:]
            let f = Self.ephemeralFormats[storageKey] ?? [true, true]
            self.showsAU = f[0]; self.showsVST3 = f[1]
        } else {
            self.entries = Self.sanitized(defaults.dictionary(forKey: storageKey))
            let order = (defaults.array(forKey: Self.categoryOrderKey) ?? []).compactMap(Self.index)
            self.categoryOrder = order.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
            self.categoryNames = Self.sanitizedNames(defaults.dictionary(forKey: Self.categoryNamesKey))
            // An absent key means "shown": `bool(forKey:)` would answer false for it.
            let au = defaults.object(forKey: Self.showsAUKey) as? Bool ?? true
            let vst = defaults.object(forKey: Self.showsVST3Key) as? Bool ?? true
            self.showsAU = au || !vst
            self.showsVST3 = vst
        }
    }

    /// A non-negative integer, or nothing (a boolean, a fraction, a string are not indices).
    nonisolated private static func index(_ v: Any) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d == d.rounded(), d < Double(Int.max) else { return nil }
        return n.intValue
    }

    /// Only non-negative integers survive a reading (a corrupted or hand-edited entry is dropped
    /// instead of being trusted). A bare index is the one-category entry of the first version.
    private static func sanitized(_ raw: [String: Any]?) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for (k, v) in raw ?? [:] {
            let list: [Int]
            if let many = v as? [Any] { list = many.compactMap(index) }
            else { list = index(v).map { [$0] } ?? [] }
            let clean = Array(Set(list)).sorted()
            if !clean.isEmpty { out[k] = clean }
        }
        return out
    }

    /// Only a non-negative index with a non-blank string survives a reading (a hand-edited or corrupted
    /// entry is dropped instead of being trusted); the name is cleaned as `setCategoryName` would.
    private static func sanitizedNames(_ raw: [String: Any]?) -> [Int: String] {
        var out: [Int: String] = [:]
        for (k, v) in raw ?? [:] {
            guard let i = Int(k), i >= 0, let text = v as? String else { continue }
            let name = cleanedName(text)
            if !name.isEmpty { out[i] = name }
        }
        return out
    }

    /// A name as it is kept: edges trimmed, line breaks turned into spaces (it is said on one line),
    /// cut to `maxNameLength`. Empty stays empty (= no name).
    static func cleanedName(_ text: String) -> String {
        let oneLine = text.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Reading

    func colorIndices(format: String, identifier: String) -> [Int] {
        entries[Self.key(format: format, identifier: identifier)] ?? []
    }

    /// The first category (the only one, for whoever gives a plugin one colour).
    func colorIndex(format: String, identifier: String) -> Int? {
        colorIndices(format: format, identifier: identifier).first
    }

    func colorIndex(forKey key: String) -> Int? { entries[key]?.first }

    /// The name the hand gave to the colour `index`; nil when it has none.
    func categoryName(_ index: Int) -> String? { categoryNames[index] }

    // MARK: Writing

    /// Gives `index` as the plugin's ONLY category, or removes its entry when `index` is nil (or
    /// negative: there is no such colour). Writes the storage only if the value actually changes.
    func set(_ index: Int?, format: String, identifier: String) {
        set(index, forKey: Self.key(format: format, identifier: identifier))
    }

    func set(_ index: Int?, forKey key: String) {
        write((index ?? -1) >= 0 ? [index!] : [], forKey: key)
    }

    /// Adds `index` to the plugin's categories, or takes it off if it was one of them.
    func toggle(_ index: Int, format: String, identifier: String) {
        guard index >= 0 else { return }
        let key = Self.key(format: format, identifier: identifier)
        var list = entries[key] ?? []
        if let at = list.firstIndex(of: index) { list.remove(at: at) } else { list.append(index) }
        write(list, forKey: key)
    }

    private func write(_ list: [Int], forKey key: String) {
        let new: [Int]? = list.isEmpty ? nil : Array(Set(list)).sorted()
        guard entries[key] != new else { return }
        entries[key] = new
        persist()
    }

    /// Remembers the colour tabs' order (the whole row, as it now stands).
    func setCategoryOrder(_ order: [Int]) {
        guard order != categoryOrder else { return }
        categoryOrder = order
        if isEphemeral { Self.ephemeralAdded[storageKey] = order }
        else { defaults.set(order, forKey: Self.categoryOrderKey) }
    }

    /// Names the colour `index` — or takes its name back when `name` is empty (blank included). A
    /// negative index is no colour. Writes the storage only if the name actually changes.
    func setCategoryName(_ name: String, for index: Int) {
        guard index >= 0 else { return }
        let clean = Self.cleanedName(name)
        guard categoryNames[index] != (clean.isEmpty ? nil : clean) else { return }
        if clean.isEmpty { categoryNames.removeValue(forKey: index) } else { categoryNames[index] = clean }
        if isEphemeral { Self.ephemeralNames[storageKey] = categoryNames }
        else {
            defaults.set(Dictionary(uniqueKeysWithValues: categoryNames.map { (String($0.key), $0.value) }),
                         forKey: Self.categoryNamesKey)
        }
    }

    /// Shows or hides the AudioUnits / the VST3s. Hiding the last format shown brings the other one
    /// back: a browser with no external plugin at all is a browser one thinks broken.
    func setShows(au: Bool, vst3: Bool) {
        var (a, v) = (au, vst3)
        if !a && !v { a = !showsAU; v = !showsVST3; if !a && !v { a = true } }
        guard a != showsAU || v != showsVST3 else { return }
        showsAU = a; showsVST3 = v
        if isEphemeral { Self.ephemeralFormats[storageKey] = [a, v] }
        else { defaults.set(a, forKey: Self.showsAUKey); defaults.set(v, forKey: Self.showsVST3Key) }
    }

    private func persist() {
        writeCount += 1
        if isEphemeral { Self.ephemeral[storageKey] = entries }
        else { defaults.set(entries, forKey: storageKey) }
    }
}

import Foundation
import Observation

// MARK: - The colour category of each plugin (plugin browser)

/// The hand's own sorting of the plugin catalogue: the colour categories of each plugin — SEVERAL
/// if the hand says so ("uncategorised" = no entry at all). It is the APP's memory, not the project's
/// — a plugin is the same plugin whatever the session — kept in `UserDefaults` under a single key, a
/// flat dictionary `"<format>|<identifier>" → [palette index]` (an entry written when a plugin had
/// ONE category is a bare index, and is still read).
///
/// The store also remembers the two other things the browser keeps from one opening to the next:
/// the ORDER the hand gave the colour tabs (`categoryOrder`) and which external formats are shown
/// (`showsAU`, `showsVST3`).
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
@Observable
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
    static let showsAUKey = "pluginBrowser.showsAU"
    static let showsVST3Key = "pluginBrowser.showsVST3"

    /// The ephemeral world, one dictionary per defaults key, shared by every store of the process.
    nonisolated(unsafe) private static var ephemeral: [String: [String: [Int]]] = [:]
    nonisolated(unsafe) private static var ephemeralAdded: [String: [Int]] = [:]
    nonisolated(unsafe) private static var ephemeralFormats: [String: [Bool]] = [:]

    /// Test door: forgets what the ephemeral world holds for `key`.
    static func resetEphemeral(for key: String = defaultsKey) {
        ephemeral.removeValue(forKey: key)
        ephemeralAdded.removeValue(forKey: key)
        ephemeralFormats.removeValue(forKey: key)
    }

    /// `key → palette indices` (ascending, distinct, never empty). Read it to draw; write it through
    /// `toggle` / `set`.
    private(set) var entries: [String: [Int]]

    /// The colour tabs' order as the hand left it (@see PluginCategoryPalette.ordered). A colour
    /// that is not in it comes after those that are.
    private(set) var categoryOrder: [Int]

    /// Which external formats the browser lists. Never both false (@see `setShows`).
    private(set) var showsAU: Bool
    private(set) var showsVST3: Bool

    /// How many times the storage was written: a change of nothing must write nothing.
    @ObservationIgnored private(set) var writeCount = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let isEphemeral: Bool

    init(defaults: UserDefaults = .standard,
         storageKey: String = PluginCategoryStore.defaultsKey,
         ephemeral: Bool = PluginCategoryStore.processIsEphemeral) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.isEphemeral = ephemeral
        if ephemeral {
            self.entries = Self.ephemeral[storageKey] ?? [:]
            self.categoryOrder = Self.ephemeralAdded[storageKey] ?? []
            let f = Self.ephemeralFormats[storageKey] ?? [true, true]
            self.showsAU = f[0]; self.showsVST3 = f[1]
        } else {
            self.entries = Self.sanitized(defaults.dictionary(forKey: storageKey))
            let order = (defaults.array(forKey: Self.categoryOrderKey) ?? []).compactMap(Self.index)
            self.categoryOrder = order.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
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

    // MARK: Reading

    func colorIndices(format: String, identifier: String) -> [Int] {
        entries[Self.key(format: format, identifier: identifier)] ?? []
    }

    /// The first category (the only one, for whoever gives a plugin one colour).
    func colorIndex(format: String, identifier: String) -> Int? {
        colorIndices(format: format, identifier: identifier).first
    }

    func colorIndex(forKey key: String) -> Int? { entries[key]?.first }

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

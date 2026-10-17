import Foundation
import Observation

// MARK: - The directions of the signal view's "+" (an app preference)

/// What each direction of a "+" of the signal view asks for (@see PlusShortcutMap, the pure model). It is the
/// APP's memory, not the project's — a habit of the hand is the same whatever the session — kept in
/// `UserDefaults` under one key, the map as JSON (`{"version": 2, "slots": {"right": {"near": …, "far": …}}}`).
///
/// One door edits it: the "+" page of the plugin browser (@see PluginBrowserPlusPage), at the far right of
/// the view a click on a "+" opens. The signal view reads `map` while drawing and on release; the store being
/// observed, a change shows at once. A map stored by an earlier version (v1) is migrated when read.
///
/// A plugin bound to a direction is remembered by `format|identifier` (@see PlusPluginRef) and KEPT when it
/// is no longer installed: the direction then shows the plugin as unavailable and does nothing, until the
/// plugin comes back or the hand puts something else there.
///
/// A test never touches the real domain: under `--no-recent` or `--headless` the map lives in the process
/// and dies with it (same discretion as `PluginCategoryStore`).
@Observable
final class PlusShortcutStore {

    /// The one store of the app.
    static let shared = PlusShortcutStore()

    static let defaultsKey = "synoptic.plusShortcuts"

    static var processIsEphemeral: Bool {
        let a = LaunchArguments.process
        return a.noRecentProjects || a.headless
    }

    /// The ephemeral world, one map per defaults key, shared by every store of the process.
    nonisolated(unsafe) private static var ephemeral: [String: PlusShortcutMap] = [:]

    /// Test door: forgets what the ephemeral world holds for `key`.
    static func resetEphemeral(for key: String = defaultsKey) { ephemeral.removeValue(forKey: key) }

    /// The map as it stands. Read it to draw and to classify; write it through the methods below.
    private(set) var map: PlusShortcutMap

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let isEphemeral: Bool

    init(defaults: UserDefaults = .standard,
         storageKey: String = PlusShortcutStore.defaultsKey,
         ephemeral: Bool = PlusShortcutStore.processIsEphemeral) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.isEphemeral = ephemeral
        if ephemeral {
            map = Self.ephemeral[storageKey] ?? .defaults
        } else if let data = defaults.data(forKey: storageKey),
                  let stored = try? JSONDecoder().decode(PlusShortcutMap.self, from: data) {
            map = stored
        } else {
            // Nothing stored, or something unreadable: the defaults (an unreadable entry is not trusted).
            map = .defaults
        }
    }

    // MARK: Writing (each one writes the storage only when the map actually changes)

    /// Puts `action` on `slot` (a swap if another slot held it, @see PlusShortcutMap.assign).
    func assign(_ action: PlusAction, to slot: PlusSlot) { mutate { $0.assign(action, to: slot) } }

    func swap(_ a: PlusSlot, _ b: PlusSlot) { mutate { $0.swap(a, b) } }

    func clear(_ slot: PlusSlot) { mutate { $0.clear(slot) } }

    /// `plugin` asks for nothing any more, wherever it was bound.
    func unbind(_ plugin: PlusPluginRef) { mutate { $0.unbind(plugin) } }

    /// The "+" as it was designed: right = gain (further: gain · pan · mute), down-right = parallel branch,
    /// left = send.
    func reset() { mutate { $0.reset() } }

    private func mutate(_ f: (inout PlusShortcutMap) -> Void) {
        var m = map
        f(&m)
        guard m != map else { return }
        map = m
        if isEphemeral {
            Self.ephemeral[storageKey] = m
        } else if let data = try? JSONEncoder().encode(m) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

import Foundation
import Observation

// MARK: - The Finder tab's colour slots

/// The six colour slots of the Finder tab (the left panel's sound library): each remembers ONE folder,
/// and a click on its colour shows that folder. It is the APP's memory, not the project's — a folder
/// of sounds is the same folder whatever the session — kept in `UserDefaults` (the app is not
/// sandboxed, so a plain path is enough: no security-scoped bookmark).
///
/// The slots wear the plugin browser's first six category colours (`PluginCategoryPalette.base`), so
/// the two colour rows read as the same control.
///
/// Also remembers WHICH slot is shown (`activeSlot`), so the Finder opens where it was left. A test
/// never touches the real domain: under `--no-recent` or `--headless` the slots live in this
/// process only and start empty (same discretion as `PluginCategoryStore`).
@Observable
final class FinderSlotStore {

    /// The one store of the app.
    static let shared = FinderSlotStore()

    static let slotsKey = "finder.slots"
    static let activeKey = "finder.activeSlot"

    /// How many slots the row has.
    static let slotCount = PluginCategoryPalette.base.count

    /// The palette index (`ObjekatPalette.pluginCategory`) a slot is painted with.
    static func colourIndex(forSlot slot: Int) -> Int {
        PluginCategoryPalette.base[((slot % slotCount) + slotCount) % slotCount]
    }

    /// One path per slot, "" = empty. Always exactly `slotCount` long.
    private(set) var paths: [String]
    /// The slot whose folder the Finder is showing, nil = none (a folder chosen outside the slots).
    private(set) var activeSlot: Int?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isEphemeral: Bool

    init(defaults: UserDefaults = .standard, ephemeral: Bool = PluginCategoryStore.processIsEphemeral) {
        self.defaults = defaults
        self.isEphemeral = ephemeral
        if ephemeral {
            paths = Array(repeating: "", count: Self.slotCount)
            activeSlot = nil
        } else {
            let stored = (defaults.array(forKey: Self.slotsKey) as? [String]) ?? []
            paths = (0..<Self.slotCount).map { $0 < stored.count ? stored[$0] : "" }
            let active = defaults.object(forKey: Self.activeKey) as? Int
            activeSlot = active.flatMap { (0..<Self.slotCount).contains($0) ? $0 : nil }
        }
    }

    /// The folder of a slot, nil when it is empty.
    func path(forSlot slot: Int) -> String? {
        guard paths.indices.contains(slot), !paths[slot].isEmpty else { return nil }
        return paths[slot]
    }

    /// Gives a slot its folder, or empties it (`nil`). Emptying the slot that is shown leaves the
    /// Finder on the folder it displays but no longer on any slot.
    func setPath(_ path: String?, forSlot slot: Int) {
        guard paths.indices.contains(slot) else { return }
        let new = path ?? ""
        guard paths[slot] != new else { return }
        paths[slot] = new
        if new.isEmpty, activeSlot == slot { activeSlot = nil; persistActive() }
        if !isEphemeral { defaults.set(paths, forKey: Self.slotsKey) }
    }

    func setActive(_ slot: Int?) {
        guard activeSlot != slot else { return }
        activeSlot = slot
        persistActive()
    }

    private func persistActive() {
        guard !isEphemeral else { return }
        if let activeSlot { defaults.set(activeSlot, forKey: Self.activeKey) }
        else { defaults.removeObject(forKey: Self.activeKey) }
    }
}

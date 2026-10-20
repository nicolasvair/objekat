import Foundation
import Observation

// MARK: - The Finder tab's colour slots

/// One slot of the Finder tab's colour row: a colour, and the folder it remembers ("" = empty).
/// `id` is the slot's identity for its whole life — the row can be REORDERED, so a position is not
/// one — and `colour` travels with it: a slot dragged elsewhere keeps its colour.
struct FinderSlot: Equatable, Identifiable, Sendable {
    let id: String
    /// An index into the plugin browser's category colours (`ObjekatPalette.pluginCategory`).
    let colour: Int
    var path: String

    var isEmpty: Bool { path.isEmpty }
}

/// The Finder tab's colour slots (the left panel's sound library): each remembers ONE folder, and a
/// click on its colour shows that folder. It is the APP's memory, not the project's — a folder of
/// sounds is the same folder whatever the session — kept in `UserDefaults` (the app is not
/// sandboxed, so a plain path is enough: no security-scoped bookmark).
///
/// The row starts with the plugin browser's first six category colours (`PluginCategoryPalette.base`),
/// so the two colour rows read as the same control. The hand can REORDER the slots (drag), ADD one
/// (the "+" at the end of the row: it takes the next colour no slot wears yet) and REMOVE one (⌥ +
/// click). Stored as `finder.slots.v2`, an array of `{id, colour, path}`; the six-paths array of the
/// first version (`finder.slots` + the `finder.activeSlot` index) is read once if v2 is absent.
///
/// Also remembers WHICH slot is shown (`activeID`), so the Finder opens where it was left. A test
/// never touches the real domain: under `--no-recent` or `--headless` the slots live in this
/// process only and start as the default row (same discretion as `PluginCategoryStore`).
@Observable
final class FinderSlotStore {

    /// The one store of the app.
    static let shared = FinderSlotStore()

    static let slotsKey = "finder.slots.v2"
    static let activeKey = "finder.activeSlotID"
    /// The first version's keys (six paths, an active INDEX): read when v2 is absent, never written.
    static let legacySlotsKey = "finder.slots"
    static let legacyActiveKey = "finder.activeSlot"

    /// The colours of the row a fresh install gets, in order.
    static var defaultColours: [Int] { PluginCategoryPalette.base }

    /// The ordered slots.
    private(set) var slots: [FinderSlot]
    /// The slot whose folder the Finder is showing, nil = none (a folder chosen outside the slots).
    private(set) var activeID: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isEphemeral: Bool

    init(defaults: UserDefaults = .standard, ephemeral: Bool = PluginCategoryStore.processIsEphemeral) {
        self.defaults = defaults
        self.isEphemeral = ephemeral
        if ephemeral {
            slots = Self.defaultRow()
            activeID = nil
            return
        }
        if let stored = defaults.array(forKey: Self.slotsKey) as? [[String: Any]] {
            var seen = Set<String>()
            slots = stored.compactMap { d in
                guard let id = d["id"] as? String, !id.isEmpty, seen.insert(id).inserted,
                      let colour = d["colour"] as? Int else { return nil }
                return FinderSlot(id: id, colour: colour, path: d["path"] as? String ?? "")
            }
            let active = defaults.string(forKey: Self.activeKey)
            activeID = slots.contains { $0.id == active } ? active : nil
        } else {
            // The first version: six paths by position, the active slot by index.
            let paths = (defaults.array(forKey: Self.legacySlotsKey) as? [String]) ?? []
            slots = Self.defaultRow(paths: paths)
            let index = defaults.object(forKey: Self.legacyActiveKey) as? Int
            activeID = index.flatMap { slots.indices.contains($0) ? slots[$0].id : nil }
        }
    }

    /// The default row: one slot per default colour, with `paths` given by position.
    static func defaultRow(paths: [String] = []) -> [FinderSlot] {
        defaultColours.enumerated().map { i, colour in
            FinderSlot(id: UUID().uuidString, colour: colour, path: i < paths.count ? paths[i] : "")
        }
    }

    /// The colour a NEW slot takes: the first of the default colours no slot wears, then the first of
    /// the whole palette no slot wears; when every colour is worn, the one worn the fewest times
    /// (earliest in that order on a tie) — so a long row still cycles evenly.
    static func nextColour(after used: [Int], paletteCount: Int = PluginCategoryPalette.count) -> Int {
        let order = defaultColours + (0..<paletteCount).filter { !defaultColours.contains($0) }
        if let free = order.first(where: { !used.contains($0) }) { return free }
        var best = order.first ?? 0
        var bestCount = Int.max
        for c in order {
            let n = used.filter { $0 == c }.count
            if n < bestCount { best = c; bestCount = n }
        }
        return best
    }

    // MARK: Reading

    func slot(_ id: String) -> FinderSlot? { slots.first { $0.id == id } }

    /// The folder of a slot, nil when it is empty (or unknown).
    func path(of id: String) -> String? {
        guard let s = slot(id), !s.isEmpty else { return nil }
        return s.path
    }

    var activeSlot: FinderSlot? { activeID.flatMap(slot) }

    // MARK: Writing

    /// Gives a slot its folder, or empties it (`nil`). Emptying the slot that is shown leaves the
    /// Finder on the folder it displays but no longer on any slot.
    func setPath(_ path: String?, for id: String) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        let new = path ?? ""
        guard slots[i].path != new else { return }
        slots[i].path = new
        if new.isEmpty, activeID == id { activeID = nil; persistActive() }
        persistSlots()
    }

    func setActive(_ id: String?) {
        let valid = id.flatMap { slot($0) == nil ? nil : $0 }
        guard activeID != valid else { return }
        activeID = valid
        persistActive()
    }

    /// Appends an EMPTY slot at the end of the row, in the next colour (@see `nextColour`).
    @discardableResult
    func addSlot() -> FinderSlot {
        let s = FinderSlot(id: UUID().uuidString, colour: Self.nextColour(after: slots.map(\.colour)), path: "")
        slots.append(s)
        persistSlots()
        return s
    }

    /// Removes a slot (its folder is only forgotten: nothing on disk is touched). The slot shown
    /// leaves the Finder on its folder, on no slot.
    func removeSlot(_ id: String) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        slots.remove(at: i)
        if activeID == id { activeID = nil; persistActive() }
        persistSlots()
    }

    /// Moves a slot so that it lands at `index` of the row AFTER the move (clamped). The drag of the
    /// row calls it with the position of the slot it was dropped on.
    func moveSlot(_ id: String, to index: Int) {
        guard let from = slots.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(slots.count - 1, index))
        guard from != to else { return }
        let s = slots.remove(at: from)
        slots.insert(s, at: to)
        persistSlots()
    }

    // MARK: Persistence

    private func persistSlots() {
        guard !isEphemeral else { return }
        defaults.set(slots.map { ["id": $0.id, "colour": $0.colour, "path": $0.path] as [String: Any] },
                     forKey: Self.slotsKey)
    }

    private func persistActive() {
        guard !isEphemeral else { return }
        if let activeID { defaults.set(activeID, forKey: Self.activeKey) }
        else { defaults.removeObject(forKey: Self.activeKey) }
    }
}

// The Finder tab's colour slots — the row the hand reorders, adds to and removes from — asserted with
// no screen.
//
// `FinderSlotStore` (`Shared/FinderSlotStore.swift`): the default row (the plugin browser's six base
// colours), the colour a new slot takes, add / remove / move by id, the active slot following its slot
// through a move and forgotten with it, the persistence as `finder.slots.v2` and the one-time reading
// of the first version's keys (`finder.slots` six paths + `finder.activeSlot` index). The persistence
// is exercised on an IN-MEMORY `UserDefaults` (`MemoryDefaults`, nothing reaches cfprefsd or a plist) —
// never the app's domain — and the ephemeral store (`--no-recent` / `--headless`) is checked to write
// nothing at all.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/FinderSlotStore.swift \
//         ../objekat/Shared/PluginBrowserModel.swift \
//         ../objekat/Shared/PluginCategoryStore.swift \
//         ../objekat/App/LaunchArguments.swift \
//         test_finder_slot_store.swift -o /tmp/fss && /tmp/fss
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

/// A `UserDefaults` that keeps everything in a dictionary: a suite (`UserDefaults(suiteName:)`) would
/// leave a plist in ~/Library/Preferences behind it.
final class MemoryDefaults: UserDefaults {
    var store: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { store[key] }
    override func array(forKey key: String) -> [Any]? { store[key] as? [Any] }
    override func string(forKey key: String) -> String? { store[key] as? String }
    override func set(_ value: Any?, forKey key: String) { store[key] = value }
    override func set(_ value: Int, forKey key: String) { store[key] = value }
    override func removeObject(forKey key: String) { store[key] = nil }
}

@main
enum FinderSlotStoreTest {
    static func main() {
        let d = MemoryDefaults()

        // ── the default row ──
        let fresh = FinderSlotStore(defaults: d, ephemeral: false)
        check("a fresh store has the six default colours, in order",
              fresh.slots.map(\.colour) == PluginCategoryPalette.base, "\(fresh.slots.map(\.colour))")
        check("every default slot is empty", fresh.slots.allSatisfy(\.isEmpty))
        check("ids are distinct", Set(fresh.slots.map(\.id)).count == fresh.slots.count)
        check("no slot is active", fresh.activeID == nil)

        // ── next colour ──
        let base = PluginCategoryPalette.base
        check("next colour: the first default colour nobody wears", FinderSlotStore.nextColour(after: [0, 3]) == 6)
        check("next colour: a removed default colour comes back first",
              FinderSlotStore.nextColour(after: base.filter { $0 != 3 }) == 3)
        let beyond = FinderSlotStore.nextColour(after: base)
        check("next colour: past the defaults, the first palette colour nobody wears",
              beyond == 1, "\(beyond)")
        let all = Array(0..<PluginCategoryPalette.count)
        check("next colour: every colour worn → the least worn, in order (a default first)",
              FinderSlotStore.nextColour(after: all) == base[0])
        check("next colour: every colour worn, one of them twice → not that one",
              FinderSlotStore.nextColour(after: all + [base[0]]) == base[1])

        // ── add / path / active / move / remove ──
        let s = FinderSlotStore(defaults: d, ephemeral: false)
        let added = s.addSlot()
        check("add: appended at the end", s.slots.last?.id == added.id && s.slots.count == 7)
        check("add: in the next colour", added.colour == 1, "\(added.colour)")
        check("add: empty", added.isEmpty)
        let first = s.slots[0].id, third = s.slots[2].id
        s.setPath("/tmp/a", for: first)
        s.setPath("/tmp/c", for: third)
        check("path(of:) reads a full slot", s.path(of: first) == "/tmp/a")
        check("path(of:) is nil for an empty slot", s.path(of: s.slots[1].id) == nil)
        s.setActive(third)
        check("setActive", s.activeID == third)
        s.setActive("nope")
        check("an unknown id makes no slot active", s.activeID == nil)
        s.setActive(third)
        s.moveSlot(third, to: 0)
        check("move: the slot lands at the index asked", s.slots[0].id == third && s.slots[1].id == first)
        check("move: it keeps its colour and its folder", s.slots[0].colour == base[2] && s.slots[0].path == "/tmp/c")
        check("move: the active slot follows it (by id)", s.activeID == third && s.activeSlot?.path == "/tmp/c")
        s.moveSlot(third, to: 99)
        check("move: an index past the end is clamped to the end", s.slots.last?.id == third)
        s.setPath(nil, for: third)
        check("emptying the active slot leaves no slot active", s.activeID == nil)
        s.setActive(first)
        s.removeSlot(first)
        check("remove: the slot is gone", s.slot(first) == nil && s.slots.count == 6)
        check("remove: the active slot removed leaves none active", s.activeID == nil)
        s.removeSlot("nope")
        check("remove: an unknown id changes nothing", s.slots.count == 6)

        // ── persistence (v2) ──
        let order = s.slots.map(\.id)
        let again = FinderSlotStore(defaults: d, ephemeral: false)
        check("v2: the order is read back", again.slots.map(\.id) == order)
        check("v2: colours and paths are read back",
              again.slots.map(\.colour) == s.slots.map(\.colour) && again.slots.map(\.path) == s.slots.map(\.path))
        let last = again.slots[0].id
        again.setPath("/tmp/z", for: last)
        again.setActive(last)
        check("v2: the active slot is read back", FinderSlotStore(defaults: d, ephemeral: false).activeID == last)
        while let id = again.slots.first?.id { again.removeSlot(id) }
        let empty = FinderSlotStore(defaults: d, ephemeral: false)
        check("v2: a row emptied by hand stays empty (not the default row back)", empty.slots.isEmpty)

        // ── the first version's keys ──
        let d1 = MemoryDefaults()
        d1.set(["/old/a", "", "/old/c", "", "", ""], forKey: FinderSlotStore.legacySlotsKey)
        d1.set(2, forKey: FinderSlotStore.legacyActiveKey)
        let mig = FinderSlotStore(defaults: d1, ephemeral: false)
        check("v1: six slots in the default colours", mig.slots.map(\.colour) == base)
        check("v1: the paths by position", mig.slots.map(\.path) == ["/old/a", "", "/old/c", "", "", ""])
        check("v1: the active INDEX becomes that slot's id", mig.activeID == mig.slots[2].id)
        check("v1: reading does not write v2", d1.object(forKey: FinderSlotStore.slotsKey) == nil)
        mig.moveSlot(mig.slots[2].id, to: 0)
        let mig2 = FinderSlotStore(defaults: d1, ephemeral: false)
        check("v1 → v2: the first write moves the row to v2", mig2.slots.first?.path == "/old/c")

        // ── ephemeral ──
        let d2 = MemoryDefaults()
        d2.set(["/real"], forKey: FinderSlotStore.legacySlotsKey)
        let eph = FinderSlotStore(defaults: d2, ephemeral: true)
        check("ephemeral: starts as the default row, whatever is stored", eph.slots.allSatisfy(\.isEmpty) && eph.slots.count == 6)
        let e = eph.addSlot()
        eph.setPath("/x", for: e.id)
        eph.setActive(e.id)
        eph.moveSlot(e.id, to: 0)
        eph.removeSlot(eph.slots[1].id)
        check("ephemeral: writes nothing",
              d2.object(forKey: FinderSlotStore.slotsKey) == nil && d2.object(forKey: FinderSlotStore.activeKey) == nil
              && (d2.array(forKey: FinderSlotStore.legacySlotsKey) as? [String]) == ["/real"])

        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty { print("FAILED:"); fails.forEach { print("  - \($0)") }; exit(1) }
        print("ALL OK")
    }
}

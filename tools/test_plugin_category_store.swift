import Foundation

// Standalone test of the plugin browser's category store (`Shared/PluginCategoryStore.swift`).
// From `tools/`:
//
//     swiftc -parse-as-library -o /tmp/t_pcs ../objekat/App/LaunchArguments.swift \
//         ../objekat/Shared/PluginCategoryStore.swift test_plugin_category_store.swift && /tmp/t_pcs

var failures = 0, total = 0
func check(_ ok: Bool, _ what: String) { total += 1; if !ok { failures += 1; print("FAIL: \(what)") } }

@main
struct Main {
    static func main() {
        let suite = "pluginbrowser.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let k = PluginCategoryStore.defaultsKey

        // The key: format + "|" + identifier, and nothing else.
        check(PluginCategoryStore.key(format: "VST3", identifier: "abc") == "VST3|abc", "key = format|identifier")
        check(PluginCategoryStore.key(format: "AudioUnit", identifier: "abc") != PluginCategoryStore.key(format: "VST3", identifier: "abc"),
              "the same identifier in two formats is two plugins")

        // Real domain (not ephemeral): empty at first.
        let s = PluginCategoryStore(defaults: defaults, ephemeral: false)
        check(s.entries.isEmpty, "a fresh store is empty")
        check(s.colorIndex(format: "VST3", identifier: "a") == nil, "uncategorised = no entry")

        // Set / read / one category per plugin.
        s.set(3, format: "VST3", identifier: "a")
        check(s.colorIndex(format: "VST3", identifier: "a") == 3, "set then read")
        check(s.colorIndex(forKey: "VST3|a") == 3, "read by key")
        s.set(5, format: "VST3", identifier: "a")
        check(s.colorIndex(format: "VST3", identifier: "a") == 5 && s.entries.count == 1, "one category per plugin: the new one replaces the old")
        check(s.writeCount == 2, "two changes, two writes")

        // Writes only on change.
        s.set(5, format: "VST3", identifier: "a")
        check(s.writeCount == 2, "the same value writes nothing")
        s.set(nil, format: "VST3", identifier: "unknown")
        check(s.writeCount == 2, "removing what is not there writes nothing")
        s.set(-1, format: "VST3", identifier: "unknown")
        check(s.writeCount == 2 && s.entries.count == 1, "a negative index is 'no category' (nothing there, nothing written)")

        // Persistence: a second store on the same defaults sees it.
        let s2 = PluginCategoryStore(defaults: defaults, ephemeral: false)
        check(s2.colorIndex(format: "VST3", identifier: "a") == 5, "persisted in UserDefaults")
        check(defaults.dictionary(forKey: k) != nil, "stored under the single key")

        // Removal.
        s2.set(nil, format: "VST3", identifier: "a")
        check(s2.entries.isEmpty, "set(nil) removes the entry")
        check(PluginCategoryStore(defaults: defaults, ephemeral: false).entries.isEmpty, "removal persisted")

        // An entry whose plugin is gone is kept (the store never sees the catalogue).
        s2.set(2, format: "AudioUnit", identifier: "gone")
        let s3 = PluginCategoryStore(defaults: defaults, ephemeral: false)
        check(s3.colorIndex(format: "AudioUnit", identifier: "gone") == 2, "an uninstalled plugin's entry is kept")

        // A corrupted / hand-edited domain is sanitised, not trusted.
        defaults.set(["ok|a": 4, "neg|a": -2, "str|a": "red", "frac|a": 1.5, "bool|a": true, "ok|b": 0] as [String: Any], forKey: k)
        let s4 = PluginCategoryStore(defaults: defaults, ephemeral: false)
        check(s4.entries == ["ok|a": [4], "ok|b": [0]], "negative, string, fractional and boolean entries are dropped (0 is a valid colour)")

        // Ephemeral: never touches the defaults; shared by the stores of the process.
        let before = defaults.dictionary(forKey: k)
        let e1 = PluginCategoryStore(defaults: defaults, storageKey: "eph.key", ephemeral: true)
        e1.set(7, format: "VST3", identifier: "z")
        check(defaults.dictionary(forKey: "eph.key") == nil, "ephemeral writes nothing into UserDefaults")
        check((defaults.dictionary(forKey: k) as NSDictionary?) == (before as NSDictionary?), "the real key is untouched")
        let e2 = PluginCategoryStore(defaults: defaults, storageKey: "eph.key", ephemeral: true)
        check(e2.colorIndex(format: "VST3", identifier: "z") == 7, "ephemeral state lives for the process")
        PluginCategoryStore.resetEphemeral(for: "eph.key")
        check(PluginCategoryStore(defaults: defaults, storageKey: "eph.key", ephemeral: true).entries.isEmpty, "resetEphemeral forgets it")

        // Several colours per plugin: toggle adds, toggles back off, keeps the list sorted.
        let m = PluginCategoryStore(defaults: defaults, storageKey: "multi.key", ephemeral: true)
        m.toggle(9, format: "VST3", identifier: "p"); m.toggle(3, format: "VST3", identifier: "p")
        check(m.colorIndices(format: "VST3", identifier: "p") == [3, 9], "two colours, ascending")
        check(m.colorIndex(format: "VST3", identifier: "p") == 3, "colorIndex = the first")
        m.toggle(3, format: "VST3", identifier: "p")
        check(m.colorIndices(format: "VST3", identifier: "p") == [9], "toggling a colour again takes it off")
        m.toggle(9, format: "VST3", identifier: "p")
        check(m.entries.isEmpty, "the last colour off = no entry")
        m.toggle(2, format: "VST3", identifier: "p"); m.toggle(5, format: "VST3", identifier: "p")
        m.set(nil, format: "VST3", identifier: "p")
        check(m.entries.isEmpty, "set(nil) clears every colour")

        // A list, and the bare index of the first version, are both read.
        defaults.set(["a|1": [7, 2, 2, -1], "a|2": 5, "a|3": [Int]()] as [String: Any], forKey: k)
        check(PluginCategoryStore(defaults: defaults, ephemeral: false).entries == ["a|1": [2, 7], "a|2": [5]],
              "lists are sorted, deduplicated and cleaned; a bare index is a list of one; an empty list is no entry")

        // The two spellings of one AudioUnit share a key.
        check(PluginCategoryStore.key(format: "AudioUnit", identifier: "AudioUnit:Effects/aufx,SpMd,oDin")
              == PluginCategoryStore.key(format: "AudioUnit", identifier: "aufx,SpMd,oDin"), "AU: JUCE's spelling = the scan's")
        check(PluginCategoryStore.key(format: "VST3", identifier: "/a/b.vst3") == "VST3|/a/b.vst3", "a VST3 path keeps its slashes")

        // The tabs' order and the shown formats.
        m.setCategoryOrder([11, 4])
        check(m.categoryOrder == [11, 4], "the tabs' order is kept as given")
        check(m.showsAU && m.showsVST3, "both formats shown at first")
        m.setShows(au: true, vst3: false)
        check(m.showsAU && !m.showsVST3, "VST3 hidden")
        m.setShows(au: false, vst3: false)
        check(!m.showsAU && m.showsVST3, "hiding the last format shown brings the other back")
        let m2 = PluginCategoryStore(defaults: defaults, storageKey: "multi.key", ephemeral: true)
        check(m2.categoryOrder == [11, 4] && !m2.showsAU && m2.showsVST3, "both survive a reopening")
        PluginCategoryStore.resetEphemeral(for: "multi.key")
        let real = PluginCategoryStore(defaults: defaults, ephemeral: false)
        real.setShows(au: false, vst3: true); real.setCategoryOrder([8, 2])
        let real2 = PluginCategoryStore(defaults: defaults, ephemeral: false)
        check(!real2.showsAU && real2.showsVST3 && real2.categoryOrder == [8, 2], "persisted in UserDefaults")

        // The names of the colours: a colour has none until it is told; empty = no name.
        PluginCategoryStore.resetEphemeral(for: "names.key")
        let n = PluginCategoryStore(defaults: defaults, storageKey: "names.key", ephemeral: true)
        check(n.categoryNames.isEmpty && n.categoryName(3) == nil, "no colour is named at first")
        n.setCategoryName("Dynamics", for: 3)
        check(n.categoryName(3) == "Dynamics" && n.categoryNames == [3: "Dynamics"], "a name, read back")
        n.setCategoryName("  Space \n echo  ", for: 9)
        check(n.categoryName(9) == "Space   echo", "edges trimmed, a line break becomes a space")
        n.setCategoryName("   ", for: 3)
        check(n.categoryName(3) == nil && n.categoryNames == [9: "Space   echo"], "a blank name takes the name back")
        n.setCategoryName("", for: 9)
        check(n.categoryNames.isEmpty, "an empty name takes the name back")
        n.setCategoryName("", for: 5)
        n.setCategoryName("x", for: -1)
        check(n.categoryNames.isEmpty, "naming nothing, or a negative index, names nothing")
        n.setCategoryName(String(repeating: "é", count: 90), for: 2)
        check(n.categoryName(2)?.count == PluginCategoryStore.maxNameLength, "a name is cut to maxNameLength")
        n.setCategoryName("Dynamics", for: 3); n.setCategoryName("Dynamics", for: 3)
        let n2 = PluginCategoryStore(defaults: defaults, storageKey: "names.key", ephemeral: true)
        check(n2.categoryName(3) == "Dynamics", "ephemeral names live for the process")
        check(defaults.dictionary(forKey: PluginCategoryStore.categoryNamesKey) == nil, "ephemeral names write nothing into UserDefaults")
        PluginCategoryStore.resetEphemeral(for: "names.key")
        check(PluginCategoryStore(defaults: defaults, storageKey: "names.key", ephemeral: true).categoryNames.isEmpty, "resetEphemeral forgets the names")

        // Real domain: kept from one opening to the next, as the tabs' order is, under their own key.
        let r = PluginCategoryStore(defaults: defaults, ephemeral: false)
        r.setCategoryName("Mix bus", for: 12)
        check(defaults.dictionary(forKey: PluginCategoryStore.categoryNamesKey) as? [String: String] == ["12": "Mix bus"], "stored as index-string → name")
        check(PluginCategoryStore(defaults: defaults, ephemeral: false).categoryName(12) == "Mix bus", "names persisted in UserDefaults")
        r.setCategoryName("", for: 12)
        check(PluginCategoryStore(defaults: defaults, ephemeral: false).categoryNames.isEmpty, "a name taken back is persisted")
        check(PluginCategoryStore(defaults: defaults, ephemeral: false).entries.isEmpty == false, "naming a colour touches no plugin's colours")

        // A hand-edited or corrupted names entry is sanitised, not trusted.
        defaults.set(["4": "Ok", "x": "NaN", "-2": "Neg", "5": "   ", "6": 7, "7": "  Trim "] as [String: Any],
                     forKey: PluginCategoryStore.categoryNamesKey)
        check(PluginCategoryStore(defaults: defaults, ephemeral: false).categoryNames == [4: "Ok", 7: "Trim"],
              "non-numeric / negative keys, blank and non-string values are dropped; names cleaned")

        // The process default follows the launch arguments (this test is launched with neither flag).
        check(PluginCategoryStore.processIsEphemeral == false, "not ephemeral without --no-recent / --headless")
        check(LaunchArguments(["x", "--headless"]).headless && LaunchArguments(["x", "--no-recent"]).noRecentProjects, "the flags the store reads exist")

        print("\(total - failures)/\(total) plugin category store checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}

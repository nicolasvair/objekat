import Foundation

// Standalone test of the plugin browser's pure model (`Shared/PluginBrowserModel.swift`).
// From `tools/`:
//
//     swiftc -parse-as-library -o /tmp/t_pbm ../objekat/App/LaunchArguments.swift \
//         ../objekat/Shared/PluginCategoryStore.swift ../objekat/Shared/PluginBrowserModel.swift \
//         test_plugin_browser_model.swift && /tmp/t_pbm

var failures = 0, total = 0
func check(_ ok: Bool, _ what: String) { total += 1; if !ok { failures += 1; print("FAIL: \(what)") } }

struct P: PluginBrowsable {
    var name: String
    var manufacturer: String = "Maker"
    var identifier: String
    var formatName: String = "VST3"
    var isInstrument: Bool = false
    var isBuiltIn: Bool { formatName == "TracktionInternal" }
}

func names<Q: PluginBrowsable>(_ s: [PluginBrowserSection<Q>]) -> [[String]] { s.map { $0.plugins.map(\.name) } }

@main
struct Main {
    static func main() {
        let eq   = P(name: "Built EQ", manufacturer: "Tracktion", identifier: "eq", formatName: "TracktionInternal")
        let verb = P(name: "Big Reverb", manufacturer: "Acme", identifier: "verb")
        let comp = P(name: "Compressor", manufacturer: "Acme", identifier: "comp", formatName: "AudioUnit")
        let synth = P(name: "Synth One", manufacturer: "Zed", identifier: "synth", isInstrument: true)
        let melo = P(name: "Melodyne", manufacturer: "Celemony", identifier: "melo")
        let catalog = [eq, verb, comp, synth, melo]
        let cats: [String: [Int]] = [
            PluginCategoryStore.key(format: "VST3", identifier: "verb"): [1],
            PluginCategoryStore.key(format: "AudioUnit", identifier: "comp"): [1],
            PluginCategoryStore.key(format: "VST3", identifier: "synth"): [4],
            PluginCategoryStore.key(format: "VST3", identifier: "ghost"): [6],   // uninstalled
        ]

        // All tab, FX only: built-in then external, instruments out, order kept.
        let all = PluginBrowserModel.sections(catalog: catalog, tab: .all, query: "", searchScope: .currentTab,
                                              kind: .effectsOnly, categories: cats)
        check(all.map(\.kind) == [.builtIn, .external], "sections in historical order")
        check(names(all) == [["Built EQ"], ["Big Reverb", "Compressor", "Melodyne"]], "built-in / external split, catalogue order, no instrument")

        // Instruments only.
        let ins = PluginBrowserModel.sections(catalog: catalog, tab: .all, query: "", searchScope: .currentTab,
                                              kind: .instrumentsOnly, categories: cats)
        check(names(ins) == [["Synth One"]] && ins[0].kind == .external, "instrument picker holds instruments only")
        let any = PluginBrowserModel.sections(catalog: catalog, searchScope: .currentTab, kind: .any, categories: cats)
        check(any.flatMap(\.plugins).count == 5, "kind .any keeps everything")

        // Empty sections are left out.
        let none = PluginBrowserModel.sections(catalog: [P](), searchScope: .currentTab, kind: .any, categories: [:])
        check(none.isEmpty, "empty catalogue, no section")

        // Colour tab.
        let c1 = PluginBrowserModel.sections(catalog: catalog, tab: .category(1), searchScope: .currentTab,
                                             kind: .effectsOnly, categories: cats)
        check(names(c1) == [["Big Reverb", "Compressor"]], "a colour tab holds the plugins of that colour (any format)")
        let c9 = PluginBrowserModel.sections(catalog: catalog, tab: .category(9), searchScope: .currentTab,
                                             kind: .any, categories: cats)
        check(c9.isEmpty, "a colour nobody has: empty")

        // Search: name OR manufacturer, case-insensitive, empty = everything.
        func q(_ s: String, tab: PluginBrowserTab = .all, scope: PluginBrowserSearchScope) -> [String] {
            PluginBrowserModel.sections(catalog: catalog, tab: tab, query: s, searchScope: scope, kind: .any, categories: cats)
                .flatMap(\.plugins).map(\.name)
        }
        check(q("REVERB", scope: .currentTab) == ["Big Reverb"], "search by name, case-insensitive")
        check(q("acme", scope: .currentTab) == ["Big Reverb", "Compressor"], "search by manufacturer")
        check(q("", scope: .currentTab).count == 5, "empty query matches all")

        // The explicit scope parameter.
        check(q("acme", tab: .category(1), scope: .currentTab) == ["Big Reverb", "Compressor"], "currentTab: tab and search intersect")
        check(q("Melodyne", tab: .category(1), scope: .currentTab).isEmpty, "currentTab: a plugin of another tab is not found")
        check(q("Melodyne", tab: .category(1), scope: .wholeCatalog) == ["Melodyne"], "wholeCatalog: the search lifts the tab")
        check(q("", tab: .category(1), scope: .wholeCatalog) == ["Big Reverb", "Compressor"], "wholeCatalog without a query still honours the tab")

        // ARA section: its own, after the externals, same search and tab, not the kind filter.
        let ara = PluginBrowserModel.sections(catalog: catalog, araCandidates: [melo], tab: .all, query: "",
                                              searchScope: .currentTab, kind: .effectsOnly, categories: cats)
        check(ara.map(\.kind) == [.builtIn, .external, .ara] && names(ara)[2] == ["Melodyne"], "ARA section last, plugin also listed as external")
        let araQ = PluginBrowserModel.sections(catalog: catalog, araCandidates: [melo], query: "verb", searchScope: .currentTab,
                                               kind: .effectsOnly, categories: cats)
        check(!araQ.contains { $0.kind == .ara }, "the ARA section follows the search")
        let araTab = PluginBrowserModel.sections(catalog: catalog, araCandidates: [melo], tab: .category(1), searchScope: .currentTab,
                                                 kind: .effectsOnly, categories: cats)
        check(!araTab.contains { $0.kind == .ara }, "the ARA section follows the tab")
        let araLifted = PluginBrowserModel.sections(catalog: catalog, araCandidates: [melo], tab: .category(1), query: "melo",
                                                    searchScope: .wholeCatalog, kind: .effectsOnly, categories: cats)
        check(araLifted.map(\.kind) == [.external, .ara], "wholeCatalog lifts the tab for ARA rows too")

        // Used categories: ascending, installed and passing the kind filter only.
        check(PluginBrowserModel.usedCategories(catalog: catalog, kind: .any, categories: cats) == [1, 4],
              "used = categories with an installed plugin (ghost's 6 excluded)")
        check(PluginBrowserModel.usedCategories(catalog: catalog, kind: .effectsOnly, categories: cats) == [1],
              "the kind filter hides a category that only holds instruments")
        check(PluginBrowserModel.usedCategories(catalog: catalog, kind: .instrumentsOnly, categories: cats) == [4], "instrument picker: colour 4 only")
        check(PluginBrowserModel.usedCategories(catalog: catalog, kind: .any, categories: [:]).isEmpty, "no category, no tab")
        check(PluginBrowserModel.usedCategories(catalog: catalog, kind: .any, categories: ["VST3|verb": [3], "VST3|melo": [0]]) == [0, 3],
              "ascending and 0 is a colour")

        // Nothing is lost or duplicated within a section set.
        let big = (0..<50).map { P(name: "p\($0)", identifier: "i\($0)", formatName: $0 % 4 == 0 ? "TracktionInternal" : "VST3") }
        let bs = PluginBrowserModel.sections(catalog: big, searchScope: .currentTab, kind: .any, categories: [:])
        check(bs.flatMap(\.plugins).count == 50, "every plugin appears once")

        // Pages: the current one while it exists, All otherwise.
        let allPage = PluginBrowserPage.all
        check(PluginBrowserModel.resolvedPage(allPage, usedCategories: [], hasFXLinkPage: false, hasSendPage: false) == allPage, "All always exists")
        check(PluginBrowserModel.resolvedPage(.plugins(.category(3)), usedCategories: [1, 3], hasFXLinkPage: false, hasSendPage: false) == .plugins(.category(3)),
              "a used colour tab stays")
        check(PluginBrowserModel.resolvedPage(.plugins(.category(3)), usedCategories: [1], hasFXLinkPage: true, hasSendPage: true) == allPage,
              "a colour tab that emptied falls back on All")
        check(PluginBrowserModel.resolvedPage(.fxLink, usedCategories: [], hasFXLinkPage: true, hasSendPage: false) == .fxLink, "FX link page stays when offered")
        check(PluginBrowserModel.resolvedPage(.fxLink, usedCategories: [], hasFXLinkPage: false, hasSendPage: true) == allPage, "FX link page gone -> All")
        check(PluginBrowserModel.resolvedPage(.send, usedCategories: [], hasFXLinkPage: true, hasSendPage: true) == .send, "Send page stays when offered")
        check(PluginBrowserModel.resolvedPage(.send, usedCategories: [], hasFXLinkPage: true, hasSendPage: false) == allPage, "Send page gone -> All")
        check(PluginBrowserModel.resolvedPage(.plusShortcuts, usedCategories: [], hasFXLinkPage: false, hasSendPage: false, hasPlusPage: true) == .plusShortcuts,
              "'+' page stays when offered (with no FX link or send page)")
        check(PluginBrowserModel.resolvedPage(.plusShortcuts, usedCategories: [], hasFXLinkPage: true, hasSendPage: true) == allPage,
              "'+' page gone (the instruments zone) -> All")
        check(!PluginBrowserPage.plusShortcuts.isPluginList, "the '+' page is not a plugin-list page")
        check(allPage.isPluginList && PluginBrowserPage.plugins(.category(2)).isPluginList && !PluginBrowserPage.fxLink.isPluginList && !PluginBrowserPage.send.isPluginList,
              "isPluginList")

        // Extra pages: only for an insertion point, never on a send's chain host.
        typealias E = (fxLink: Bool, send: Bool)
        func extra(_ ins: Bool, _ bin: Bool, _ sendChain: Bool, _ canSend: Bool) -> E {
            PluginBrowserModel.extraPages(hasInsertion: ins, insertionInsideBin: bin, hostIsSendChain: sendChain, hostCanSend: canSend)
        }
        check(extra(true, false, false, true) == (true, true), "an object's trunk '+': both pages")
        check(extra(true, true, false, true) == (false, true), "inside a bin: no FX link page, the send page stays (greyed by the view)")
        check(extra(true, false, false, false) == (true, false), "an aux / a stem / the Main cannot send")
        check(extra(false, false, false, true) == (false, false), "no insertion point (instrument picker, send's '+'): neither page")
        check(extra(true, false, true, true) == (false, false), "a send's chain host holds neither")

        // One row per plugin: the scan's description and JUCE's resolved one are the same AudioUnit.
        let auScan = P(name: "Space", identifier: "aufx,SpMd,oDin", formatName: "AudioUnit")
        let auJuce = P(name: "Space", identifier: "AudioUnit:Effects/aufx,SpMd,oDin", formatName: "AudioUnit")
        let vstA = P(name: "Space", manufacturer: "Valhalla", identifier: "/L/Space.vst3")
        let vstB = P(name: "Space", manufacturer: "com.valhalla", identifier: "/L/Space.vst3")
        let dup = [auJuce, auScan, vstA, vstB, eq]
        let ds = PluginBrowserModel.sections(catalog: dup, searchScope: .wholeCatalog, kind: .any, categories: [:])
        check(names(ds) == [["Built EQ"], ["Space", "Space"]], "two descriptions of one plugin = one row (AU + VST3 stay two)")
        check(ds[1].plugins.map(\.identifier) == ["AudioUnit:Effects/aufx,SpMd,oDin", "/L/Space.vst3"], "the first met is kept")
        check(ds[1].plugins[1].manufacturer == "Valhalla", "VST3: the first description's manufacturer")

        // The format switch: built-ins always, AU and VST3 each on their own.
        func shown(_ f: PluginBrowserFormats) -> [[String]] {
            names(PluginBrowserModel.sections(catalog: dup, searchScope: .wholeCatalog, kind: .any, formats: f, categories: [:]))
        }
        check(shown(.init(au: true, vst3: false)) == [["Built EQ"], ["Space"]], "VST3 hidden: the AU row and the built-in")
        check(shown(.init(au: false, vst3: true)) == [["Built EQ"], ["Space"]], "AU hidden: the VST3 row and the built-in")
        check(PluginBrowserModel.usedCategories(catalog: dup, kind: .any, formats: .init(au: false, vst3: true),
                                                categories: ["AudioUnit|aufx,SpMd,oDin": [2], "VST3|/L/Space.vst3": [5]]) == [5],
              "a colour only carried by a hidden format has no tab")

        // Several colours: a plugin is on each of its tabs.
        let multi: [String: [Int]] = ["VST3|verb": [1, 4], "VST3|melo": [4]]
        func tab(_ i: Int) -> [[String]] {
            names(PluginBrowserModel.sections(catalog: catalog, tab: .category(i), searchScope: .wholeCatalog, kind: .effectsOnly, categories: multi))
        }
        check(tab(1) == [["Big Reverb"]] && tab(4) == [["Big Reverb", "Melodyne"]], "a plugin with two colours is on both tabs")
        check(PluginBrowserModel.usedCategories(catalog: catalog, kind: .effectsOnly, categories: multi) == [1, 4], "used = the union")

        // The menu's swatches: six to start with, then the colours in use. One nobody uses is gone.
        check(PluginCategoryPalette.offered(inUse: []) == [0, 3, 6, 9, 12, 14], "six base colours")
        check(PluginCategoryPalette.offered(inUse: [15, 7, 3, 99]) == [0, 3, 6, 9, 12, 14, 7, 15],
              "then the colours in use; no repeat, nothing outside the palette")
        check(PluginCategoryPalette.offered(inUse: [7, 3, 12], order: [12, 9, 7]) == [12, 7, 0, 3, 6, 9, 14],
              "the menu follows the tabs' order: ordered colours in use first, the rest behind")
        check(PluginCategoryPalette.remaining(offered: [0, 3, 6, 9, 12, 14]).count == 10, "the '+' offers the ten others")
        check(PluginCategoryPalette.remaining(offered: Array(0..<16)).isEmpty, "nothing left: no '+'")

        // The tabs' order.
        check(PluginCategoryPalette.ordered(used: [1, 4, 9], order: []) == [1, 4, 9], "no order given: ascending")
        check(PluginCategoryPalette.ordered(used: [1, 4, 9], order: [9, 7, 1]) == [9, 1, 4], "the hand's order, unused colours skipped, new ones last")
        check(PluginCategoryPalette.moved([9, 1, 4], from: 0, to: 2) == [1, 4, 9], "first tab dropped last")
        check(PluginCategoryPalette.moved([9, 1, 4], from: 2, to: 0) == [4, 9, 1], "last tab dropped first")
        check(PluginCategoryPalette.moved([9, 1, 4], from: 1, to: 1) == [9, 1, 4], "dropped where it was")

        // The search field's small language.
        let uad = P(name: "UAD Pultec EQP-1A", identifier: "u1")
        let uadx = P(name: "UADx Neve 1073", identifier: "u2")
        let quad = P(name: "Quadravox", manufacturer: "Eventide", identifier: "u3")
        let cat2 = [uad, uadx, quad, verb]
        func found(_ q: String) -> [String] { cat2.filter { PluginBrowserModel.matches($0, query: q) }.map(\.name) }
        check(found("-uad") == ["Big Reverb"], "-uad hides every name containing uad")
        check(found("-\"uad\"") == ["UADx Neve 1073", "Quadravox", "Big Reverb"], "-\"uad\" hides only the exact word")
        check(found("\"uad\"") == ["UAD Pultec EQP-1A"], "\"uad\" asks for the exact word")
        check(found("\u{201C}uad\u{201D}") == ["UAD Pultec EQP-1A"], "typographic quotes too")
        check(found("uad -neve") == ["UAD Pultec EQP-1A", "Quadravox"], "a phrase and an exclusion together")
        check(found("-") == found("") && found("-\"") == found("") && found("").count == 4, "an unfinished token filters nothing")
        check(found("neve 1073") == ["UADx Neve 1073"], "plain text is still one phrase")
        check(found("-\"neve 1073\"") == ["UAD Pultec EQP-1A", "Quadravox", "Big Reverb"], "quoted words that follow one another")
        check(found("eventide") == ["Quadravox"] && found("-eventide").count == 4, "the phrase reads the manufacturer, an exclusion only the name")
        // A field that only hides keeps the tab; a real search lifts it.
        let oneTab: [String: [Int]] = ["VST3|u1": [2], "VST3|u2": [2]]
        func onTab(_ q: String) -> [[String]] {
            names(PluginBrowserModel.sections(catalog: cat2, tab: .category(2), query: q, searchScope: .wholeCatalog, kind: .any, categories: oneTab))
        }
        check(onTab("-neve") == [["UAD Pultec EQP-1A"]], "an exclusion alone filters INSIDE the tab")
        check(onTab("reverb") == [["Big Reverb"]], "a search still looks everywhere")

        print("\(total - failures)/\(total) plugin browser model checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}

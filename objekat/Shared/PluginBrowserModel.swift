import Foundation

// MARK: - What the plugin browser shows (pure)

/// The catalogue as the browser needs it. `AvailablePlugin` already has every one of these members
/// (the conformance is declared next to the view), which keeps this file free of the model's
/// dependencies — and testable alone, with no screen.
protocol PluginBrowsable {
    var name: String { get }
    var manufacturer: String { get }
    var identifier: String { get }
    var formatName: String { get }
    var isInstrument: Bool { get }
    var isBuiltIn: Bool { get }
}

/// The browser's tab: everything, or the plugins the hand gave one colour (among others, maybe).
enum PluginBrowserTab: Hashable {
    case all
    case category(Int)
}

/// The browser's PAGE: the plugin list (on a tab), or one of the pages that are not plugins at all —
/// the FX links this host could join, the targets of a send taken at the insertion point, and the "+"
/// page (what each direction of the signal view's "+" asks for — it shows the plugin list too, but a
/// click there binds the plugin to a direction instead of inserting it).
enum PluginBrowserPage: Hashable {
    case plugins(PluginBrowserTab)
    case fxLink
    case send
    case plusShortcuts

    static let all: PluginBrowserPage = .plugins(.all)

    var isPluginList: Bool {
        if case .plugins = self { return true }
        return false
    }
}

/// What a typed search runs over. An explicit parameter: the choice is the interface's to make.
enum PluginBrowserSearchScope {
    /// Only the current tab's plugins.
    case currentTab
    /// The whole catalogue, whatever the tab (the tab filter is lifted while there is a search).
    case wholeCatalog
}

/// Instrument / effect split of the catalogue. An FX chain takes no instrument (it needs MIDI at its
/// input); the instruments zone of a MIDI clip takes nothing else.
enum PluginBrowserKindFilter {
    case any
    case instrumentsOnly
    case effectsOnly
}

/// Which external formats are listed (the built-ins always are).
struct PluginBrowserFormats: Equatable {
    var au = true
    var vst3 = true
}

/// The colours a category can take: indices into the plugin palette. Six are offered from the start,
/// far apart on the colour wheel; the menu's "+" gives a plugin one of the others.
enum PluginCategoryPalette {
    static let count = 16
    static let base = [0, 3, 6, 9, 12, 14]

    /// The swatches of the menu, in order: the base, then every other colour a plugin CARRIES. A
    /// colour taken from the "+" is therefore there for as long as one plugin has it, and gone —
    /// back behind the "+" — when the last one gives it up.
    /// `order` is the tabs' order: the colours it names come first, as the tab bar shows them, so
    /// the menu and the bar read the same way.
    static func offered(inUse: [Int], order: [Int] = []) -> [Int] {
        var out = base
        for i in inUse.sorted() where i >= 0 && i < count && !out.contains(i) { out.append(i) }
        let first = order.filter { inUse.contains($0) && out.contains($0) }
        return first + out.filter { !first.contains($0) }
    }

    /// The colour tabs in the hand's order: the colours `order` names first, as it names them, then
    /// the others ascending (a colour used for the first time lands at the end).
    static func ordered(used: [Int], order: [Int]) -> [Int] {
        let known = order.filter { used.contains($0) }
        return known + used.sorted().filter { !known.contains($0) }
    }

    /// `tabs` with the tab at `from` taken out and put back at `to` (an index in the row WITHOUT it,
    /// @see TabReorder.targetIndex).
    static func moved(_ tabs: [Int], from: Int, to: Int) -> [Int] {
        guard tabs.indices.contains(from) else { return tabs }
        var out = tabs
        let item = out.remove(at: from)
        out.insert(item, at: max(0, min(to, out.count)))
        return out
    }

    /// What the "+" still has to offer.
    static func remaining(offered: [Int]) -> [Int] { (0..<count).filter { !offered.contains($0) } }
}

/// What the search field says, read once. Words are typed as they come:
/// - plain text is ONE phrase, looked for in the name or the manufacturer;
/// - `-uad` HIDES every plugin whose name contains "uad";
/// - `-"uad"` hides those whose name has the WORD "uad" exactly ("UAD Pultec", not "UADx Neve");
/// - `"uad"` alone asks for that word.
struct PluginBrowserQuery: Equatable {
    var phrase = ""
    var words: [[String]] = []
    var excluded: [String] = []
    var excludedWords: [[String]] = []

    /// False when the field only HIDES things (or is empty): the tab then still applies.
    var asksForSomething: Bool { !phrase.isEmpty || !words.isEmpty }
    var isEmpty: Bool { !asksForSomething && excluded.isEmpty && excludedWords.isEmpty }

    private static let quotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{00AB}", "\u{00BB}"]

    init(_ text: String) {
        var plain: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace { i = text.index(after: i); continue }
            var minus = false
            if text[i] == "-" { minus = true; i = text.index(after: i) }
            var token = ""
            var quoted = false
            if i < text.endIndex, Self.quotes.contains(text[i]) {
                quoted = true
                i = text.index(after: i)
                while i < text.endIndex, !Self.quotes.contains(text[i]) { token.append(text[i]); i = text.index(after: i) }
                if i < text.endIndex { i = text.index(after: i) }
            } else {
                while i < text.endIndex, !text[i].isWhitespace { token.append(text[i]); i = text.index(after: i) }
            }
            // A bare "-" or an empty pair of quotes says nothing yet: the hand is still typing.
            if quoted {
                let w = Self.wordList(token)
                if !w.isEmpty { if minus { excludedWords.append(w) } else { words.append(w) } }
            } else if !token.isEmpty {
                if minus { excluded.append(token) } else { plain.append(token) }
            }
        }
        phrase = plain.joined(separator: " ")
    }

    /// The words of a name: runs of letters and digits, case and accents folded.
    static func wordList(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// True if `needle`'s words follow one another somewhere in `hay`.
    static func hasWords(_ needle: [String], in hay: [String]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        return (0...(hay.count - needle.count)).contains { Array(hay[$0..<($0 + needle.count)]) == needle }
    }
}

enum PluginBrowserSectionKind {
    case builtIn
    case external
    /// "ARA source": VST3 an audio object plays THROUGH (their rows are ALSO rows of `.external`).
    case ara
}

struct PluginBrowserSection<P> {
    let kind: PluginBrowserSectionKind
    let plugins: [P]
}

enum PluginBrowserModel {

    /// The kind filter alone (also what the tab strip counts on).
    static func passes<P: PluginBrowsable>(_ p: P, kind: PluginBrowserKindFilter) -> Bool {
        switch kind {
        case .any: return true
        case .instrumentsOnly: return p.isInstrument
        case .effectsOnly: return !p.isInstrument
        }
    }

    /// Name OR manufacturer, case- and diacritic-insensitive as the historical picker was. An empty
    /// query matches everything.
    static func matches<P: PluginBrowsable>(_ p: P, query: String) -> Bool {
        matches(p, query: PluginBrowserQuery(query))
    }

    /// The phrase in the name OR the manufacturer; the asked words and everything HIDDEN are read in
    /// the NAME alone (`-uad` is about what a plugin is called, not about who makes it).
    static func matches<P: PluginBrowsable>(_ p: P, query q: PluginBrowserQuery) -> Bool {
        if q.isEmpty { return true }
        if !q.phrase.isEmpty, !p.name.localizedCaseInsensitiveContains(q.phrase),
           !p.manufacturer.localizedCaseInsensitiveContains(q.phrase) { return false }
        if q.excluded.contains(where: { p.name.localizedCaseInsensitiveContains($0) }) { return false }
        if !q.words.isEmpty || !q.excludedWords.isEmpty {
            let name = PluginBrowserQuery.wordList(p.name)
            if !q.words.allSatisfy({ PluginBrowserQuery.hasWords($0, in: name) }) { return false }
            if q.excludedWords.contains(where: { PluginBrowserQuery.hasWords($0, in: name) }) { return false }
        }
        return true
    }

    /// `categories`: the store's `key → palette indices` (@see PluginCategoryStore).
    static func belongs<P: PluginBrowsable>(_ p: P, to tab: PluginBrowserTab, categories: [String: [Int]]) -> Bool {
        switch tab {
        case .all: return true
        case .category(let i):
            return categories[PluginCategoryStore.key(format: p.formatName, identifier: p.identifier)]?.contains(i) ?? false
        }
    }

    /// The format switch: a built-in is always listed, an unknown format too.
    static func passes<P: PluginBrowsable>(_ p: P, formats: PluginBrowserFormats) -> Bool {
        if p.isBuiltIn { return true }
        switch p.formatName {
        case "AudioUnit": return formats.au
        case "VST3":      return formats.vst3
        default:          return true
        }
    }

    /// One row per plugin. The known list holds TWO descriptions of a plugin that was instantiated
    /// once (the scan's, and the one JUCE resolved — @see PluginCategoryStore.normalizedIdentifier):
    /// the first met is kept. The catalogue itself is left alone, a saved plugin being looked up in
    /// it under either spelling.
    static func deduplicated<P: PluginBrowsable>(_ catalog: [P]) -> [P] {
        var seen = Set<String>()
        return catalog.filter { seen.insert(PluginCategoryStore.key(format: $0.formatName, identifier: $0.identifier)).inserted }
    }

    /// The sections to draw, in the historical order (built-in, external, ARA source), empty ones
    /// left out. `araCandidates` is what the view-model offers as ARA sources for the host object
    /// (empty when the host takes none, or in the instrument picker): they follow the same tab and
    /// the same search as the rest, but not the instrument/FX split (they are never instruments).
    /// The order given by `catalog` is kept inside each section.
    static func sections<P: PluginBrowsable>(
        catalog: [P],
        araCandidates: [P] = [],
        tab: PluginBrowserTab = .all,
        query: String = "",
        searchScope: PluginBrowserSearchScope,
        kind: PluginBrowserKindFilter,
        formats: PluginBrowserFormats = PluginBrowserFormats(),
        categories: [String: [Int]]
    ) -> [PluginBrowserSection<P>] {
        // A search over the whole catalogue lifts the tab: the hand is looking for a name, not a shelf.
        // A field that only HIDES things (`-uad`) is a filter, not a search: the tab stays.
        let query = PluginBrowserQuery(query)
        let tabApplies = !query.asksForSomething || searchScope == .currentTab
        let effectiveTab: PluginBrowserTab = tabApplies ? tab : .all

        // The kind filter BEFORE the deduplication: the two descriptions of one plugin may disagree
        // on "instrument", and the one that fits the picker must not be hidden by the other.
        let visible = deduplicated(catalog.filter { passes($0, kind: kind) && passes($0, formats: formats) }).filter {
            matches($0, query: query) && belongs($0, to: effectiveTab, categories: categories)
        }
        let ara = deduplicated(araCandidates.filter { passes($0, formats: formats) }).filter {
            matches($0, query: query) && belongs($0, to: effectiveTab, categories: categories)
        }

        var out: [PluginBrowserSection<P>] = []
        let builtIns = visible.filter(\.isBuiltIn)
        let externals = visible.filter { !$0.isBuiltIn }
        if !builtIns.isEmpty { out.append(.init(kind: .builtIn, plugins: builtIns)) }
        if !externals.isEmpty { out.append(.init(kind: .external, plugins: externals)) }
        if !ara.isEmpty { out.append(.init(kind: .ara, plugins: ara)) }
        return out
    }

    /// The palette indices that hold at least one plugin the browser can show (installed AND passing
    /// `kind`), ascending: the tab strip offers those and no other. A category that only holds an
    /// uninstalled plugin, or plugins the kind filter hides, gets no tab.
    static func usedCategories<P: PluginBrowsable>(
        catalog: [P],
        kind: PluginBrowserKindFilter,
        formats: PluginBrowserFormats = PluginBrowserFormats(),
        categories: [String: [Int]]
    ) -> [Int] {
        var used = Set<Int>()
        for p in catalog where passes(p, kind: kind) && passes(p, formats: formats) {
            used.formUnion(categories[PluginCategoryStore.key(format: p.formatName, identifier: p.identifier)] ?? [])
        }
        return used.sorted()
    }

    /// The page to show: `current` while it still exists, "All" when it does not (the colour of the
    /// tab was taken off its last plugin, the host stopped being able to take a bin or a send...).
    static func resolvedPage(
        _ current: PluginBrowserPage,
        usedCategories: [Int],
        hasFXLinkPage: Bool,
        hasSendPage: Bool,
        hasPlusPage: Bool = false
    ) -> PluginBrowserPage {
        switch current {
        case .plugins(.all):          return current
        case .plugins(.category(let i)): return usedCategories.contains(i) ? current : .all
        case .fxLink:                 return hasFXLinkPage ? current : .all
        case .send:                   return hasSendPage ? current : .all
        case .plusShortcuts:          return hasPlusPage ? current : .all
        }
    }

    /// Which of the two extra pages the browser offers. Both exist ONLY for an insertion point of an
    /// FX chain (`hasInsertion`: the signal view's "+"; the instruments zone and a send's own "+" have
    /// none), and never for a send's chain host (a send holds neither a bin nor a send).
    /// - FX link: not inside a bin's own series (a bin does not hold a bin).
    /// - Send: the host must be able to send (an object that is not an aux; no stem, no Main).
    static func extraPages(
        hasInsertion: Bool,
        insertionInsideBin: Bool,
        hostIsSendChain: Bool,
        hostCanSend: Bool
    ) -> (fxLink: Bool, send: Bool) {
        guard hasInsertion, !hostIsSendChain else { return (false, false) }
        return (!insertionInsideBin, hostCanSend)
    }
}

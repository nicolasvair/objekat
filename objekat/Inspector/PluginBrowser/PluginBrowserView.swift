import SwiftUI
import AppKit

// MARK: - The plugin browser (the sheet opened by the signal view's "+")

extension AvailablePlugin: PluginBrowsable {}

/// The size of the browser's sheet, in ONE place.
enum PluginBrowserLayout {
    static let sheetWidth: CGFloat = 560
    /// Twice the old sheet's width, but barely taller than its 420: at 840 it filled the window.
    static let sheetHeight: CGFloat = 520
    /// ...but never taller than the window it hangs from, minus this margin.
    static let windowMargin: CGFloat = 60
    static let minimumHeight: CGFloat = 320
    /// The "+" page wants the circle AND room for the palette below it: the sheet grows on that page only.
    static let plusSheetHeight: CGFloat = 860

    /// `mainWindow`, never `keyWindow`: while the sheet is up it IS the key window, and a size read
    /// from it would shrink the sheet it is sizing.
    static func sheetSize(plusPage: Bool = false) -> CGSize {
        let rect = NSApp.mainWindow?.contentLayoutRect
        let wanted = plusPage ? plusSheetHeight : sheetHeight
        let height = rect.map { max(minimumHeight, min(wanted, $0.height - windowMargin)) } ?? wanted
        return CGSize(width: sheetWidth(windowWidth: rect?.width), height: height)
    }

    /// Three columns of the same width as the two (the sheet half as wide again), when that still
    /// fits in this share of the app's window; two otherwise.
    static let wideSheetWidth: CGFloat = 840
    static let maxWindowShare: CGFloat = 0.70

    static func sheetWidth(windowWidth: CGFloat?) -> CGFloat {
        guard let windowWidth, wideSheetWidth <= windowWidth * maxWindowShare else { return sheetWidth }
        return wideSheetWidth
    }

    static func columnCount(sheetWidth width: CGFloat) -> Int { width >= wideSheetWidth ? 3 : 2 }
}

/// Where the signal view's "+" was clicked: what the two extra pages (FX link, send) need to place
/// their result exactly there. nil for the pickers that have no insertion point (the instruments
/// zone, a send's own "+").
struct PluginBrowserInsertion {
    let location: SeriesLocation
    let index: Int

    var isInsideBin: Bool {
        if case .block = location { return true }
        return false
    }
    var isOnTrunk: Bool {
        if case .root = location { return true }
        return false
    }
}

/// A plugin selection sheet reused by '+' (insert), '//' (branch), the instruments zone and a send's
/// box. A full-frame column: header, tab bar, search pill (plugin pages only), scrolling content,
/// then the footer as the LAST child (a footer laid as a safe-area inset over a list that scrolls
/// under it, with no background, was drawn on top of the rows).
///
/// Pages: "All", one tab per colour the hand has already given to a plugin (right click on a row), — for an
/// insertion point of an FX chain only — "FX link" and "Send", and at the far right — for any effect picker —
/// "+", what each direction of the signal view's "+" asks for (@see PluginBrowserPlusPage).
struct PluginBrowserView: View {
    var viewModel: EditViewModel
    let objectID: UUID
    let title: String
    @Binding var searchText: String
    let dismiss: () -> Void
    /// If supplied, it replaces the default addition (an append) — inserting at a precise index
    /// from the signal view, say. Otherwise: the historical behaviour (addPlugin at the end).
    var onSelect: ((AvailablePlugin) -> Void)? = nil
    /// Instruments only (the instrument area of a MIDI clip), or effects only (every FX chain: an
    /// instrument needs MIDI at its input, which only a MIDI clip provides).
    var kind: PluginBrowserKindFilter = .effectsOnly
    /// The "ARA source" section (Melodyne-like VST3 an audio object plays THROUGH). False for the
    /// instrument picker of a MIDI clip and for a send's chain.
    var showsARASource: Bool = true
    /// The "+" this sheet was opened from (nil = no FX link page, no send page).
    var insertion: PluginBrowserInsertion? = nil
    /// The colour categories: the app's memory, shared by every browser.
    var categories: PluginCategoryStore = .shared
    /// The page the sheet opens on (a "+" direction bound to a colour category opens on its tab).
    var initialPage: PluginBrowserPage = .plugins(.all)

    @FocusState private var searchFocused: Bool
    /// The page the hand chose; nil = still `initialPage`.
    @State private var chosenPage: PluginBrowserPage? = nil
    private var page: PluginBrowserPage {
        get { chosenPage ?? initialPage }
        nonmutating set { chosenPage = newValue }
    }
    @State private var outsideClickMonitor: Any? = nil
    /// The colour tab being dragged along the bar (its place in the row, the hand's travel).
    @State private var colourDrag: (from: Int, dx: CGFloat)? = nil

    // MARK: Derived

    /// The VST3 the pre-filter marks as ARA candidates and the session has not disproved: asked of the
    /// view-model at every render (so at every opening of the browser), never kept in the view. The
    /// search is applied by the model, with the rest.
    private var araCandidates: [AvailablePlugin] {
        guard showsARASource else { return [] }
        return viewModel.araPickerCandidates(for: objectID)
    }

    /// Which of the two extra pages this host / this "+" can offer (@see PluginBrowserModel.extraPages).
    private var extraPages: (fxLink: Bool, send: Bool) {
        PluginBrowserModel.extraPages(
            hasInsertion: insertion != nil,
            insertionInsideBin: insertion?.isInsideBin ?? false,
            hostIsSendChain: viewModel.isSendChainHost(objectID),
            hostCanSend: viewModel.find(id: objectID).map { !$0.isAux } ?? false)
    }

    /// The "+" page exists for every EFFECT picker (a "+" of an FX chain, of a send's chain, a branch): the
    /// directions are bound to effects only, so the instruments zone has no use for it.
    private var hasPlusPage: Bool { kind != .instrumentsOnly }

    private var formats: PluginBrowserFormats {
        PluginBrowserFormats(au: categories.showsAU, vst3: categories.showsVST3)
    }

    /// The colours that hold a plugin, in the order the hand gave their tabs.
    private var usedCategories: [Int] {
        PluginCategoryPalette.ordered(
            used: PluginBrowserModel.usedCategories(catalog: viewModel.availablePlugins, kind: kind,
                                                    formats: formats, categories: categories.entries),
            order: categories.categoryOrder)
    }

    /// The page on screen: the chosen one while it still exists, "All" otherwise.
    private var currentPage: PluginBrowserPage {
        PluginBrowserModel.resolvedPage(page, usedCategories: usedCategories,
                                        hasFXLinkPage: extraPages.fxLink, hasSendPage: extraPages.send,
                                        hasPlusPage: hasPlusPage)
    }

    private var sections: [PluginBrowserSection<AvailablePlugin>] {
        let tab: PluginBrowserTab
        if case .plugins(let t) = currentPage { tab = t } else { tab = .all }
        return PluginBrowserModel.sections(
            catalog: viewModel.availablePlugins,
            araCandidates: araCandidates,
            tab: tab,
            query: searchText,
            // Typing brings the bar back to "All" (@see the `searchText` observer); a colour clicked
            // AFTER that narrows the search to its tab, so the tab on screen is always the one read.
            searchScope: .currentTab,
            kind: kind,
            formats: formats,
            categories: categories.entries)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            switch currentPage {
            case .plugins:
                searchRow
                content
            case .fxLink:
                if let insertion {
                    PluginBrowserFXLinkPage(viewModel: viewModel, objectID: objectID,
                                            insertion: insertion, dismiss: dismiss)
                }
            case .send:
                if let insertion {
                    PluginBrowserSendPage(viewModel: viewModel, objectID: objectID,
                                          insertion: insertion, dismiss: dismiss)
                }
            case .plusShortcuts:
                // The circle, then the palette its zones are filled from by drag and drop.
                PluginBrowserPlusPage(viewModel: viewModel,
                                      plugins: listedSections.filter { $0.kind != .ara }.flatMap(\.plugins),
                                      categories: usedCategories) { searchRow }
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity)
        // The sheet's height follows the page: taller on the "+" page, which lays its palette under the circle.
        .frame(height: PluginBrowserLayout.sheetSize(plusPage: currentPage == .plusShortcuts).height)
        .onChange(of: searchText) { old, new in
            // A search STARTS: back to "All". Only then — a colour picked while searching stays.
            guard PluginBrowserQuery(new).asksForSomething, !PluginBrowserQuery(old).asksForSomething,
                  case .plugins(let tab) = currentPage, tab != .all else { return }
            page = .plugins(.all)
        }
        .onChange(of: usedCategories) { _, _ in
            // The colour of the tab we were on was taken off its last plugin: stay on "All".
            let resolved = currentPage
            if resolved != page { page = resolved }
        }
        .onAppear {
            viewModel.pluginBrowserOpen = true
            if viewModel.availablePlugins.isEmpty && !viewModel.isScanning {
                viewModel.scanPlugins()
            }
            // The browser has to be readable over the open editors. Those are floating windows (a
            // level above any ordinary window of the app): a sheet cannot get past them, so we
            // lower them again for the length of the selection.
            viewModel.setPluginEditorsFloating(false)
            // Deferred by one runloop turn: the field is not in the window yet at this point.
            DispatchQueue.main.async { searchFocused = true }
            // A click in the app's window, beside the sheet, closes it (and is not passed on: it
            // must not also move a clip). A menu's clicks never come this way.
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                guard let window = event.window, window.attachedSheet != nil else { return event }
                dismiss()
                return nil
            }
        }
        .onDisappear {
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            outsideClickMonitor = nil
            viewModel.setPluginEditorsFloating(true)
            viewModel.pluginBrowserOpen = false
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(L("common.cancel")) { dismiss() }
        }
        .padding(12)
    }

    // MARK: Tab bar

    /// "All" and the colours on the left, the two pages that are not plugin lists on the right. Capsules
    /// like the project tabs' (`WorkspaceTabBar`), on the window's recessed ground.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    tabCapsule(.all) { Text(L("pluginBrowser.tab.all")) }
                    let tabs = usedCategories
                    ForEach(Array(tabs.enumerated()), id: \.element) { position, index in
                        tabCapsule(.plugins(.category(index)), help: L("pluginBrowser.tab.colour.help")) {
                            Circle().fill(ObjekatPalette.pluginCategory(index)).frame(width: 9, height: 9)
                        }
                        .offset(x: colourTabOffset(position, count: tabs.count))
                        .zIndex(colourDrag?.from == position ? 1 : 0)
                        .gesture(colourTabDrag(position, tabs: tabs))
                    }
                }
            }
            if extraPages.fxLink || extraPages.send || hasPlusPage {
                Divider().frame(height: 12)
                if extraPages.fxLink {
                    tabCapsule(.fxLink) { Text(L("pluginBrowser.tab.fxLink")) }
                }
                if extraPages.send {
                    tabCapsule(.send) { Text(L("pluginBrowser.tab.send")) }
                }
                // Far right, always last.
                if hasPlusPage {
                    tabCapsule(.plusShortcuts, help: L("pluginBrowser.tab.plus.help")) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .accessibilityLabel(L("pluginBrowser.tab.plus.help"))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// Content + `onTapGesture` rather than a `Button` (the project tabs' choice): no focus ring, and
    /// the search field's focus is handed back by hand in `select`.
    private func tabCapsule<Label: View>(_ target: PluginBrowserPage, help: String? = nil,
                                         @ViewBuilder label: () -> Label) -> some View {
        let active = currentPage == target
        return label()
            .capsuleTab(active: active)
            .onTapGesture { select(target) }
            .accessibilityAddTraits(.isButton)
            .helpIf(help)
    }

    // MARK: Reordering the colour tabs (the project tabs' gesture, @see TabReorder)

    /// Every colour tab has the same width — a 9 pt dot between two 10 pt paddings — so the frames the
    /// reorder is judged against need no measuring.
    private static let colourTabWidth: CGFloat = 29
    private static let colourTabSpacing: CGFloat = 4

    private func colourTabFrames(_ count: Int) -> [CGRect] {
        (0..<count).map {
            CGRect(x: CGFloat($0) * (Self.colourTabWidth + Self.colourTabSpacing), y: 0,
                   width: Self.colourTabWidth, height: 20)
        }
    }

    /// The dragged tab follows the hand; its neighbours slide aside to show where it would land.
    private func colourTabOffset(_ position: Int, count: Int) -> CGFloat {
        guard let drag = colourDrag else { return 0 }
        if drag.from == position { return drag.dx }
        let frames = colourTabFrames(count)
        let target = TabReorder.targetIndex(frames: frames, dragged: drag.from, dx: drag.dx)
        return TabReorder.shift(of: position, dragged: drag.from, target: target,
                                frames: frames, spacing: Self.colourTabSpacing)
    }

    private func colourTabDrag(_ position: Int, tabs: [Int]) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { colourDrag = (position, $0.translation.width) }
            .onEnded { value in
                let target = TabReorder.targetIndex(frames: colourTabFrames(tabs.count), dragged: position,
                                                    dx: value.translation.width)
                colourDrag = nil
                categories.setCategoryOrder(PluginCategoryPalette.moved(tabs, from: position, to: target))
                refocusSearch()
            }
    }

    private func select(_ target: PluginBrowserPage) {
        page = target
        refocusSearch(on: target)
    }

    /// The search field takes the keyboard back after a tab change and after a menu — on the plugin
    /// pages and the "+" page, the only ones that have a field. Deferred: a field that was just
    /// (re)created is not in the window yet.
    private func refocusSearch(on target: PluginBrowserPage? = nil) {
        let page = target ?? currentPage
        guard page.isPluginList || page == .plusShortcuts else { return }
        DispatchQueue.main.async { searchFocused = true }
    }

    // MARK: Search

    /// A pill, like the sidechain strip's.
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary).font(.system(size: 11))
            TextField(L("common.search"), text: $searchText)
                .textFieldStyle(.plain).font(.system(size: 12))
                .focused($searchFocused)
            if !searchText.isEmpty {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary).font(.system(size: 11))
                    .contentShape(Rectangle())
                    .onTapGesture { searchText = ""; refocusSearch() }
                    .help(L("pluginBrowser.search.clear"))
                    .accessibilityLabel(L("pluginBrowser.search.clear"))
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
    }

    /// The search pill, and at its right the two formats one can hide (kept from one opening to the
    /// next by the store: whoever works in AudioUnits only does not want every plugin twice).
    private var searchRow: some View {
        HStack(spacing: 6) {
            searchField
            formatChip(ObjectPlugin.label(for: "AudioUnit"), on: categories.showsAU) {
                categories.setShows(au: !categories.showsAU, vst3: categories.showsVST3)
            }
            formatChip(ObjectPlugin.label(for: "VST3"), on: categories.showsVST3) {
                categories.setShows(au: categories.showsAU, vst3: !categories.showsVST3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Content + `onTapGesture`, like the tabs: the search field keeps the keyboard.
    private func formatChip(_ label: String, on: Bool, toggle: @escaping () -> Void) -> some View {
        Text(verbatim: label)
            .font(.system(size: 10, weight: on ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(on ? Color.primary : Color.secondary.opacity(0.6))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(on ? 0.14 : 0.04)))
            .contentShape(Rectangle())
            .onTapGesture { toggle(); refocusSearch() }
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Plugin pages

    /// Two columns, three on the wide sheet (@see PluginBrowserLayout.sheetWidth).
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6),
              count: PluginBrowserLayout.columnCount(sheetWidth: PluginBrowserLayout.sheetSize().width))
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.availablePlugins.isEmpty {
            VStack(spacing: 6) {
                if viewModel.isScanning {
                    ProgressView().controlSize(.small)
                    Text(L("plugins.scanning")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("plugins.none"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("plugins.scan")) { viewModel.scanPlugins() }
                        .controlSize(.small)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(listedSections, id: \.kind) { section in
                        // ONE list for the plugins — built-in or external is what the row's badge
                        // says. Only the ARA sources, which are another gesture, keep a title.
                        if section.kind == .ara { sectionHeader(L("plugins.section.ara")) }
                        else { Color.clear.frame(height: 8) }
                        LazyVGrid(columns: columns, spacing: 6) {
                            if section.kind == .ara {
                                // Own identity: these plugins are ALSO rows of the external section above,
                                // in the same LazyVStack — sharing their ids made SwiftUI drop these rows.
                                ForEach(section.plugins, id: \.identifier) { plugin in araRow(plugin) }
                            } else {
                                ForEach(section.plugins) { plugin in pluginRow(plugin) }
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The footer: the divider ABOVE it is laid by the column, the buttons are the last child.
    private var footer: some View {
        HStack(spacing: 12) {
            Button(viewModel.isScanning ? L("plugins.scanningShort") : L("plugins.rescan")) {
                viewModel.rescanPlugins()
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .buttonStyle(.plain)
            .disabled(viewModel.isScanning)

            Button(L("plugins.diagnostic")) {
                viewModel.diagnosticScanPlugins()
            }
            .font(.system(size: 10))
            .foregroundStyle(.quaternary)
            .buttonStyle(.plain)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
    }

    /// The model's sections with the built-in and the external plugins folded into one list, by name. On
    /// the "+" page, the plain effects only: an ARA source is not a plugin a direction can insert.
    private var listedSections: [PluginBrowserSection<AvailablePlugin>] {
        let all = sections
        let plusPage = currentPage == .plusShortcuts
        let plugins = all.filter { $0.kind != .ara }.flatMap(\.plugins)
            .filter { !plusPage || $0.canBindToPlusDirection }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (plugins.isEmpty ? [] : [PluginBrowserSection(kind: .external, plugins: plugins)])
            + (plusPage ? [] : all.filter { $0.kind == .ara })
    }

    /// What a format badge stands for, spelled out (its tooltip).
    private func formatFullName(_ formatName: String) -> String {
        switch formatName {
        case "TracktionInternal": return L("plugins.section.builtIn")
        case "AudioUnit":         return "Audio Unit"
        default:                  return formatName
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    /// The category dots of a row, one per colour the plugin was given (nothing when it has none:
    /// they sit at the row's trailing side, so the names stay aligned either way).
    @ViewBuilder
    private func categoryDots(_ plugin: AvailablePlugin) -> some View {
        let indices = categories.colorIndices(format: plugin.formatName, identifier: plugin.identifier)
        if !indices.isEmpty {
            HStack(spacing: 2) {
                ForEach(indices, id: \.self) { index in
                    Circle().fill(ObjekatPalette.pluginCategory(index)).frame(width: 7, height: 7)
                }
            }
        }
    }

    /// A candidate ARA source. Greyed, with the reason as its tooltip, when this object cannot take one.
    @ViewBuilder
    private func araRow(_ plugin: AvailablePlugin) -> some View {
        let refusal = viewModel.araPickerRefusal(for: objectID)
        PluginBrowserCard(enabled: refusal == nil, action: {
            dismiss()
            viewModel.addARASourceFromPicker(objectID: objectID, available: plugin)
        }) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.name)
                        .font(.system(size: 11))
                        .foregroundStyle(refusal == nil ? .primary : .tertiary)
                        .lineLimit(1)
                    Text(plugin.manufacturer)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                categoryDots(plugin)
                Text(verbatim: "ARA")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(refusal == nil ? Color.accentColor : Color.secondary.opacity(0.5))
            }
        }
        .overlay(categoryMenuOverlay(for: plugin))
        .help(refusal?.localizedInfo ?? L("plugins.ara.help"))
    }

    @ViewBuilder
    private func pluginRow(_ plugin: AvailablePlugin) -> some View {
        PluginBrowserCard(action: {
            if let onSelect { onSelect(plugin) }
            else { viewModel.addPlugin(objectID: objectID, available: plugin) }
            dismiss()
        }) {
            PluginBrowserRowLabel(plugin: plugin)
        }
        .overlay(categoryMenuOverlay(for: plugin))
        .help(L("pluginBrowser.row.help"))
        // Above the right-click layer, over the badge alone: the badge's own tooltip.
        .overlay(alignment: .trailing) {
            Text(plugin.formatLabel)
                .font(.system(size: 9, design: .monospaced))
                .padding(.vertical, 6).padding(.horizontal, 8)
                .hidden()
                .help(formatFullName(plugin.formatName))
        }
    }

    // MARK: Category menu (right click on a row)

    /// A transparent layer that answers the RIGHT click only (@see RightClickCaptureView): the left
    /// click, the hover and the wheel of the row below it are untouched. The menu is built at the click.
    private func categoryMenuOverlay(for plugin: AvailablePlugin) -> some View {
        RightClickMenuOverlay(menu: { categoryMenu(for: plugin) },
                              onClose: { refocusSearch() })
    }

    /// A row of swatches — six to start with, then the other colours a plugin carries, then the "+"
    /// that gives one more — and "Uncategorised". A plugin takes SEVERAL colours: a click on a swatch gives it that
    /// colour or takes it back. Written into the shared store: the tabs and the dots follow, the store
    /// being observed.
    private func categoryMenu(for plugin: AvailablePlugin) -> NSMenu {
        let store = categories
        let format = plugin.formatName
        let identifier = plugin.identifier
        let current = store.colorIndices(format: format, identifier: identifier)
        let inUse = Array(Set(store.entries.values.joined()))
        let offered = PluginCategoryPalette.offered(inUse: inUse, order: store.categoryOrder)
        let remaining = PluginCategoryPalette.remaining(offered: offered)

        let menu = NSMenu()
        menu.autoenablesItems = false

        let row = CategorySwatchRowView(indices: offered, ringed: Set(current), showsPlus: !remaining.isEmpty,
                                        onPick: { store.toggle($0, format: format, identifier: identifier) },
                                        onPlus: {
            let at = NSEvent.mouseLocation
            CategorySwatchRowView.popUpLater(at: at, indices: remaining) { index in
                store.toggle(index, format: format, identifier: identifier)
            }
        })
        let rowItem = NSMenuItem()
        rowItem.view = row
        menu.addItem(rowItem)
        menu.addItem(.separator())

        // The item holds its proxy (`representedObject` is strong, an item's target is weak).
        let proxy = MenuActionProxy { store.set(nil, format: format, identifier: identifier) }
        let none = NSMenuItem(title: L("pluginBrowser.category.none"),
                              action: #selector(MenuActionProxy.run), keyEquivalent: "")
        none.target = proxy
        none.representedObject = proxy
        none.state = current.isEmpty ? .on : .off
        menu.addItem(none)
        return menu
    }
}

// MARK: - The category menu's row of swatches

/// Swatches of the category palette, eight to a row, each one RINGED when the plugin has that colour
/// (several can be), and — last — a "+" that offers the colours not shown yet. A click toggles and
/// closes the menu. Its own small view rather than `ColorSwatchGridView`: that one rings one cell.
final class CategorySwatchRowView: NSView {
    private static let swatch: CGFloat = 18, gap: CGFloat = 7, insetX: CGFloat = 14, insetY: CGFloat = 7
    private let columns: Int

    private let indices: [Int]
    private let ringed: Set<Int>
    private let showsPlus: Bool
    private let onPick: (Int) -> Void
    private let onPlus: (() -> Void)?

    override var isFlipped: Bool { true }

    /// `columns`: 8 for the plugin's own row (it wraps past that); the "+"'s menu asks for ONE line.
    init(indices: [Int], ringed: Set<Int> = [], showsPlus: Bool = false, columns: Int = 8,
         onPick: @escaping (Int) -> Void, onPlus: (() -> Void)? = nil) {
        self.columns = max(1, columns)
        self.indices = indices
        self.ringed = ringed
        self.showsPlus = showsPlus
        self.onPick = onPick
        self.onPlus = onPlus
        let cells = indices.count + (showsPlus ? 1 : 0)
        let cols = min(self.columns, max(1, cells))
        let rows = max(1, (cells + self.columns - 1) / self.columns)
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: Self.insetX * 2 + CGFloat(cols) * Self.swatch + CGFloat(cols - 1) * Self.gap,
                                 height: Self.insetY * 2 + CGFloat(rows) * Self.swatch + CGFloat(rows - 1) * Self.gap))
        if showsPlus {
            addToolTip(rect(indices.count), owner: L("menu.context.color.add.title") as NSString, userData: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func rect(_ cell: Int) -> NSRect {
        NSRect(x: Self.insetX + CGFloat(cell % columns) * (Self.swatch + Self.gap),
               y: Self.insetY + CGFloat(cell / columns) * (Self.swatch + Self.gap),
               width: Self.swatch, height: Self.swatch)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (cell, index) in indices.enumerated() {
            let r = rect(cell)
            NSColor(ObjekatPalette.pluginCategory(index)).setFill()
            NSBezierPath(ovalIn: r).fill()
            if ringed.contains(index) {
                NSColor.labelColor.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
        if showsPlus {
            let r = rect(indices.count)
            NSColor.secondaryLabelColor.setStroke()
            let circle = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            circle.lineWidth = 1
            circle.stroke()
            let cross = NSBezierPath()
            let c = NSPoint(x: r.midX, y: r.midY), a: CGFloat = 4
            cross.move(to: NSPoint(x: c.x - a, y: c.y)); cross.line(to: NSPoint(x: c.x + a, y: c.y))
            cross.move(to: NSPoint(x: c.x, y: c.y - a)); cross.line(to: NSPoint(x: c.x, y: c.y + a))
            cross.lineWidth = 1.2
            cross.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (cell, index) in indices.enumerated() where rect(cell).insetBy(dx: -3, dy: -3).contains(p) {
            onPick(index)
            enclosingMenuItem?.menu?.cancelTracking()
            return
        }
        if showsPlus, rect(indices.count).insetBy(dx: -3, dy: -3).contains(p) {
            onPlus?()
            enclosingMenuItem?.menu?.cancelTracking()
        }
    }

    /// The "+"'s own small menu: the colours not offered yet, one click. Opened on the NEXT turn of
    /// the run loop — the menu that held the "+" is still tracking when the click lands, and a second
    /// `popUp` started inside its event would be swallowed by it.
    static func popUpLater(at screenPoint: NSPoint, indices: [Int], onPick: @escaping (Int) -> Void) {
        // NOT `DispatchQueue.main.async`: the main queue is drained in the common run loop modes, and
        // menu tracking is one of them — the block ran while the first menu was still up, and the
        // second `popUp` was swallowed (the "+" seemed dead). `.default` only comes back once the
        // first menu has really closed.
        RunLoop.main.perform(inModes: [.default, .modalPanel]) {
            let menu = NSMenu(title: L("menu.context.color.add.title"))
            menu.autoenablesItems = false
            let header = NSMenuItem(title: L("menu.context.color.add.title"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let item = NSMenuItem()
            item.view = CategorySwatchRowView(indices: indices, columns: indices.count, onPick: onPick)
            menu.addItem(item)
            menu.popUp(positioning: nil, at: screenPoint, in: nil)
        }
    }
}

// MARK: - A card (the synoptic's card vocabulary)

/// A full-width button dressed like the signal view's cards: `controlBackgroundColor`, radius 8,
/// the accent at 12 % under the pointer. Shared by the plugin rows, the FX link rows and the send rows.
/// What a plugin row of the browser shows: name and maker, the category dots, the format badge. One
/// definition for the colour tabs and the "+" page's palette (@see PluginBrowserPlusPage).
struct PluginBrowserRowLabel: View {
    let plugin: AvailablePlugin
    var categories: PluginCategoryStore = .shared

    var body: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(plugin.manufacturer)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            let indices = categories.colorIndices(format: plugin.formatName, identifier: plugin.identifier)
            if !indices.isEmpty {
                HStack(spacing: 2) {
                    ForEach(indices, id: \.self) { index in
                        Circle().fill(ObjekatPalette.pluginCategory(index)).frame(width: 7, height: 7)
                    }
                }
            }
            Text(plugin.formatLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}

struct PluginBrowserCard<Label: View>: View {
    var enabled: Bool = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering && enabled ? Color.accentColor.opacity(0.12)
                                          : Color(nsColor: .controlBackgroundColor))
        )
        .onHover { hovering = $0 }
    }
}

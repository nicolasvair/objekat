import AppKit

// MARK: - The menu bar keeps only what the app answers to

/// AppKit lays entries of its own into the menus a SwiftUI app declares: in Edit, Writing Tools,
/// AutoFill, Start Dictation and Emoji & Symbols; and a View menu (Enter Full Screen, the tab bar) and a
/// Help menu (the help search) that this app has no use for. None of them is a SwiftUI command group, so
/// emptying groups is not enough: they are taken off the menu bar here, and again every time SwiftUI or
/// AppKit rebuilds or adds to a menu (`didAddItemNotification`), since either may lay them back.
///
/// Dictation and the character palette have their own documented switches (`NSDisabled…MenuItem`),
/// registered as DEFAULTS only — nothing is written into the user's preferences.
enum MainMenuCleanup {
    private static var installed = false
    private static var pending = false

    static func install() {
        guard !installed else { return }
        installed = true
        UserDefaults.standard.register(defaults: [
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil,
                                               queue: .main) { _ in schedule() }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                               queue: .main) { _ in MainActor.assumeIsolated { clean() } }
        schedule()
    }

    /// Coalesced, and never inside the notification: a menu is not mutated while it is being added to.
    private static func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async {
            pending = false
            MainActor.assumeIsolated { clean() }
        }
    }

    /// Selectors (lowercased fragments) of the entries AppKit adds to Edit and that go.
    private static let unwantedActionFragments = [
        "writingtools", "dictation", "characterpalette", "autofill", "insertfromcontacts", "insertfrompasswords",
    ]

    /// What a View menu holds: a top-level menu made of these alone (or empty) goes.
    private static let viewActions: Set<String> = [
        "toggleFullScreen:", "toggleToolbarShown:", "runToolbarCustomizationPalette:", "toggleSidebar:",
        "toggleTabBar:", "toggleTabOverview:", "toggleInspector:",
    ]

    @MainActor
    static func clean() {
        guard let main = NSApp.mainMenu else { return }
        for top in main.items.reversed() {
            guard let sub = top.submenu else { continue }
            if sub === NSApp.helpMenu || isViewMenu(sub, at: main.index(of: top)) {
                main.removeItem(top)
                continue
            }
            prune(sub)
        }
    }

    private static func isUnwanted(_ item: NSItem) -> Bool {
        if let a = item.action {
            let name = NSStringFromSelector(a).lowercased()
            if unwantedActionFragments.contains(where: name.contains) { return true }
        }
        if let id = item.identifier?.rawValue.lowercased(),
           unwantedActionFragments.contains(where: id.contains) { return true }
        // A submenu (AutoFill, Writing Tools) goes when what it holds goes.
        if let sub = item.submenu, !sub.items.isEmpty,
           sub.items.allSatisfy({ $0.isSeparatorItem || isUnwanted($0) }) { return true }
        return false
    }

    private static func prune(_ menu: NSMenu) {
        for item in menu.items.reversed() where isUnwanted(item) { menu.removeItem(item) }
        // No separator left at an end, nor two in a row.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem {
                if previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = true }
            } else {
                previousWasSeparator = false
            }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    /// The View menu: not the app menu (index 0) nor the Window menu, made only of view toggles — or left
    /// empty by SwiftUI (an empty top-level menu has nothing to offer anyway).
    private static func isViewMenu(_ menu: NSMenu, at index: Int) -> Bool {
        guard index > 0, menu !== NSApp.windowsMenu else { return false }
        let real = menu.items.filter { !$0.isSeparatorItem }
        if real.isEmpty { return true }
        return real.allSatisfy { $0.action.map { viewActions.contains(NSStringFromSelector($0)) } ?? false }
    }

    private typealias NSItem = NSMenuItem
}

import AppKit

// The "Send to…" menu as a real NSMenu, built and shown at the CLICK (INC 2, step 2.11).
//
// Not a SwiftUI `Menu`: its content closure is evaluated while the parent renders, and the sections cost
// a topology of the project (`sendRefusals`); a signal view has a "+ Send to…" button, one trunk insert
// point per plugin and a menu per card, redrawn on every meter tick. Built here, the cost is paid once per
// OPENING. The data is the pure `SendTargetMenu`; this file only turns it into items.

@MainActor
enum SendTargetMenuPresenter {

    /// One menu item's action, kept alive by the item itself (`representedObject`: an item's target is weak).
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private static func item(_ title: String, enabled: Bool = true, run: (() -> Void)? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let run, enabled {
            let a = Action(run)
            it.target = a
            it.action = #selector(Action.fire)
            it.representedObject = a
        } else {
            it.isEnabled = false
        }
        return it
    }

    /// The menu, not yet shown (tested nowhere headless, but built from tested data).
    static func menu(sections: [SendTargetMenu.Section],
                     onPick: @escaping (UUID) -> Void,
                     onChoose: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if sections.isEmpty {
            menu.addItem(item(L("send.menu.none"), enabled: false))
        }
        for (i, section) in sections.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem(title: L(section.titleKey), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for e in section.entries {
                // A greyed entry says why in its own title: a disabled item shows no tooltip.
                let title = e.disabledReason.map { "\(e.name) — \($0)" } ?? e.name
                let it = item(title, enabled: e.isEnabled) { onPick(e.id) }
                it.indentationLevel = 1
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item(L("send.menu.choose"), run: onChoose))
        return menu
    }

    /// Opens the menu under the mouse (screen coordinates: no view).
    static func present(sections: [SendTargetMenu.Section],
                        onPick: @escaping (UUID) -> Void,
                        onChoose: @escaping () -> Void) {
        menu(sections: sections, onPick: onPick, onChoose: onChoose)
            .popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

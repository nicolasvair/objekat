import AppKit
import SwiftUI

// MARK: - The model (pure: no view, no engine, no view-model)

/// One row of a tree picker. The sidechain's source picker was the first reader (the stems, then the
/// objects as a tree of groups); the audio menu is the second (card, rate, buffer). A native `Menu`
/// could not do either: a submenu's title is not clickable on macOS, a menu closes on every click,
/// and a disabled item cannot say WHY it is disabled.
///
/// Four roles. A `choice` is a row one can pick; when it has `children` it carries a chevron that
/// opens them (the chevron never chooses, the name does). A `header` is a caption, not choosable, whose
/// children are always shown one level in. A `note` is one line of grey text, not choosable. A `branch`
/// is a row that ONLY opens and closes its children (the whole row is the button), with the current
/// value in grey at its right: the audio menu's Output / Input / Rate / Buffer.
struct TreePickerNode: Identifiable, Equatable {
    enum Role: Equatable { case choice, header, note, branch }

    let id: String
    var name: String
    var checked: Bool = false
    /// Why the row cannot be chosen: it stays visible, greyed, with this sentence as its help.
    var disabledReason: String? = nil
    var children: [TreePickerNode] = []
    /// False = not choosable whatever the role (a `header` and a `note` are never choosable).
    var selectable: Bool = true
    var role: Role = .choice
    /// A `branch`'s current value, in grey at the right of its name.
    var detail: String? = nil
    /// A `branch` that is open when the popover first appears, whatever is ticked under it.
    var startsOpen: Bool = false

    static func header(_ id: String, _ name: String, children: [TreePickerNode] = []) -> TreePickerNode {
        TreePickerNode(id: id, name: name, children: children, selectable: false, role: .header)
    }

    static func note(_ id: String, _ text: String) -> TreePickerNode {
        TreePickerNode(id: id, name: text, selectable: false, role: .note)
    }

    static func branch(_ id: String, _ name: String, detail: String?, startsOpen: Bool = false,
                       children: [TreePickerNode]) -> TreePickerNode {
        TreePickerNode(id: id, name: name, children: children, selectable: false, role: .branch,
                       detail: detail, startsOpen: startsOpen)
    }

    /// Can a click on the name choose it?
    var isChoosable: Bool { role == .choice && selectable && disabledReason == nil }

    /// This row, or something under it, is the ticked one.
    var containsChecked: Bool { checked || children.contains { $0.containsChecked } }

    /// True if `id` is somewhere under `node` (the picker opens the groups holding the current choice).
    static func contains(_ id: String, under node: TreePickerNode) -> Bool {
        node.children.contains { $0.id == id || contains(id, under: $0) }
    }
}

/// A block of rows with an optional title. A titled section can be folded.
struct TreePickerSection: Identifiable, Equatable {
    let id: String
    /// nil = the rows stand with no title (the sidechain's « None »).
    var title: String? = nil
    var nodes: [TreePickerNode]
    /// A section with a title folds by a click on it (the stems start folded, the objects open).
    var collapsible: Bool = true
    var initiallyOpen: Bool = true
    /// Said, in grey, when the section is open and has no row.
    var emptyText: String? = nil
    /// A thin line after the section.
    var dividerAfter: Bool = false
}

enum TreePickerModel {
    /// What is open when the popover first appears: every group that leads to a ticked row, and every
    /// section that is `initiallyOpen` or holds one. A `branch` opens when it `startsOpen`, or — unless
    /// `opensCheckedBranches` is false (the audio menu, which opens on folded lines) — when a ticked row is
    /// under it. The groups inside a branch behave as anywhere else. Pure.
    static func seed(_ sections: [TreePickerSection],
                     opensCheckedBranches: Bool = true) -> (nodes: Set<String>, sections: Set<String>) {
        var nodes = Set<String>()
        var open = Set<String>()
        func walk(_ list: [TreePickerNode]) {
            for n in list {
                switch n.role {
                case .branch:
                    if n.startsOpen || (opensCheckedBranches && n.containsChecked) { nodes.insert(n.id) }
                    walk(n.children)
                case .header:
                    walk(n.children)
                case .choice, .note:
                    if n.containsChecked && !n.children.isEmpty {
                        nodes.insert(n.id)
                        walk(n.children)
                    }
                }
            }
        }
        for s in sections {
            walk(s.nodes)
            if s.initiallyOpen || s.nodes.contains(where: { $0.containsChecked }) { open.insert(s.id) }
        }
        return (nodes, open)
    }

    /// The open set after a click on the branch `id`: open becomes closed; closed becomes open and, with
    /// `accordion`, closes the other `siblings` (only one line of a menu open at a time). Pure.
    static func toggled(_ id: String, expanded: Set<String>, siblings: [String], accordion: Bool) -> Set<String> {
        var result = expanded
        if result.contains(id) {
            result.remove(id)
        } else {
            result.insert(id)
            if accordion { for other in siblings where other != id { result.remove(other) } }
        }
        return result
    }

    /// The width a row needs: indent, chevron, gap, padding, tick, gap, text, slack.
    static func rowWidth(textWidth: CGFloat, depth: Int) -> CGFloat {
        CGFloat(depth) * 14 + 14 + 4 + 8 + 9 + 5 + ceil(textWidth) + 12 + 16
    }

    /// The widest row, FOLDED ONES INCLUDED (so unfolding never makes the popover jump), given a text
    /// measure. Headers push their children one level in. Pure given `measure`.
    static func widest(_ sections: [TreePickerSection], measure: (String) -> CGFloat) -> CGFloat {
        var widest: CGFloat = 0
        func walk(_ list: [TreePickerNode], _ depth: Int) {
            for n in list {
                // A branch also says its current value, a gap away from its name.
                let text = measure(n.name) + (n.detail.map { 12 + measure($0) } ?? 0)
                widest = max(widest, rowWidth(textWidth: text, depth: depth))
                walk(n.children, depth + 1)
            }
        }
        for s in sections { walk(s.nodes, s.title == nil ? 0 : 1) }
        return widest
    }
}

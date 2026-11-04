import AppKit
import SwiftUI

// MARK: - The model (pure: no view, no engine, no view-model)

/// One row of a tree picker. The sidechain's source picker was the first reader (the stems, then the
/// objects as a tree of groups); the audio menu is the second (card, rate, buffer). A native `Menu`
/// could not do either: a submenu's title is not clickable on macOS, a menu closes on every click,
/// and a disabled item cannot say WHY it is disabled.
///
/// Three roles. A `choice` is a row one can pick; when it has `children` it carries a chevron that
/// opens them (the chevron never chooses, the name does). A `header` is a caption, not choosable, whose
/// children are always shown one level in. A `note` is one line of grey text, not choosable.
struct TreePickerNode: Identifiable, Equatable {
    enum Role: Equatable { case choice, header, note }

    let id: String
    var name: String
    var checked: Bool = false
    /// Why the row cannot be chosen: it stays visible, greyed, with this sentence as its help.
    var disabledReason: String? = nil
    var children: [TreePickerNode] = []
    /// False = not choosable whatever the role (a `header` and a `note` are never choosable).
    var selectable: Bool = true
    var role: Role = .choice

    static func header(_ id: String, _ name: String, children: [TreePickerNode] = []) -> TreePickerNode {
        TreePickerNode(id: id, name: name, children: children, selectable: false, role: .header)
    }

    static func note(_ id: String, _ text: String) -> TreePickerNode {
        TreePickerNode(id: id, name: text, selectable: false, role: .note)
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
    /// section that is `initiallyOpen` or holds one. Pure.
    static func seed(_ sections: [TreePickerSection]) -> (nodes: Set<String>, sections: Set<String>) {
        var nodes = Set<String>()
        var open = Set<String>()
        func walk(_ list: [TreePickerNode]) {
            for n in list where n.containsChecked && !n.children.isEmpty {
                nodes.insert(n.id)
                walk(n.children)
            }
        }
        for s in sections {
            walk(s.nodes)
            if s.initiallyOpen || s.nodes.contains(where: { $0.containsChecked }) { open.insert(s.id) }
        }
        return (nodes, open)
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
                widest = max(widest, rowWidth(textWidth: measure(n.name), depth: depth))
                walk(n.children, depth + 1)
            }
        }
        for s in sections { walk(s.nodes, s.title == nil ? 0 : 1) }
        return widest
    }
}

// MARK: - The view

/// A list in a transient popover: sections (foldable), a tree of rows, headers, notes, rows greyed with
/// their reason. It owns only what is open; WHAT is listed and ticked comes from `sections`, a closure
/// evaluated in `body`, so a model it reads through observation (`@Observable`) re-draws the popover in
/// place — which is what lets the audio menu stay open and tick the new choice.
struct TreePickerPopover: View {
    let sections: () -> [TreePickerSection]
    /// True: a choice dismisses the popover (the sidechain). False: it stays, until a click elsewhere
    /// (the audio menu, where one sets a card, then a rate, then a buffer).
    var closesOnChoose = true
    var minWidth: CGFloat = 280
    let onChoose: (String) -> Void
    let dismiss: () -> Void

    @State private var expanded: Set<String> = []
    /// Sections the hand folded or unfolded; absent = the section's own default.
    @State private var sectionOverrides: [String: Bool] = [:]
    @State private var seeded = false

    var body: some View {
        let list = sections()
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list) { s in
                    sectionView(s)
                }
            }
            .padding(6)
        }
        .frame(width: Self.width(for: list, minWidth: minWidth))
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { seed(list) }
    }

    // MARK: Width

    static func width(for sections: [TreePickerSection], minWidth: CGFloat = 280) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11)
        let widest = TreePickerModel.widest(sections) { ($0 as NSString).size(withAttributes: [.font: font]).width }
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.width ?? 1200
        return min(max(minWidth, widest), max(minWidth, screen - 80))
    }

    // MARK: State

    private func seed(_ list: [TreePickerSection]) {
        guard !seeded else { return }
        seeded = true
        let s = TreePickerModel.seed(list)
        expanded.formUnion(s.nodes)
        for section in list where section.title != nil && !section.initiallyOpen && s.sections.contains(section.id) {
            sectionOverrides[section.id] = true
        }
    }

    private func isOpen(_ s: TreePickerSection) -> Bool {
        guard s.title != nil, s.collapsible else { return true }
        return sectionOverrides[s.id] ?? s.initiallyOpen
    }

    private func choose(_ id: String) {
        onChoose(id)
        if closesOnChoose { dismiss() }
    }

    // MARK: Pieces

    private func sectionView(_ s: TreePickerSection) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            if let title = s.title { sectionTitle(title, section: s) }
            if isOpen(s) {
                if s.nodes.isEmpty, let empty = s.emptyText { emptyLine(empty) }
                nodes(s.nodes, depth: s.title == nil ? 0 : 1)
            }
            if s.dividerAfter { Divider().padding(.vertical, 3) }
        })
    }

    private func nodes(_ list: [TreePickerNode], depth: Int) -> AnyView {
        AnyView(ForEach(list) { n in
            VStack(alignment: .leading, spacing: 0) {
                switch n.role {
                case .header:
                    headerLine(n.name, depth: depth)
                    nodes(n.children, depth: depth + 1)
                case .note:
                    noteLine(n.name, depth: depth)
                case .choice:
                    row(n, depth: depth)
                    if expanded.contains(n.id) { nodes(n.children, depth: depth + 1) }
                }
            }
        })
    }

    private func sectionTitle(_ title: String, section s: TreePickerSection) -> some View {
        let open = isOpen(s)
        return Button {
            guard s.collapsible else { return }
            sectionOverrides[s.id] = !open
        } label: {
            HStack(spacing: 4) {
                if s.collapsible {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 12)
                }
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.leading, 30)
            .padding(.vertical, 3)
    }

    /// A caption inside a section: not choosable, not foldable.
    private func headerLine(_ text: String, depth: Int) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(depth) * 14 + 18)
            .padding(.top, 5)
            .padding(.bottom, 2)
    }

    /// One line of grey explanation, wrapped when it is long.
    private func noteLine(_ text: String, depth: Int) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, CGFloat(depth) * 14 + 18)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
    }

    private func row(_ n: TreePickerNode, depth: Int) -> some View {
        let expandable = !n.children.isEmpty
        return HStack(spacing: 4) {
            // The chevron: opens / closes a group's children; it never chooses.
            Group {
                if expandable {
                    Button {
                        if expanded.contains(n.id) { expanded.remove(n.id) } else { expanded.insert(n.id) }
                    } label: {
                        Image(systemName: expanded.contains(n.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 14, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("sidechain.picker.children"))
                } else {
                    Color.clear.frame(width: 14, height: 18)
                }
            }
            // The name: chooses this row (a group whole, when it is one).
            Button { choose(n.id) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(n.checked ? 1 : 0)
                    Text(verbatim: n.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(TreePickerRowStyle())
            .disabled(!n.isChoosable)
            .help(n.disabledReason ?? "")
        }
        .padding(.leading, CGFloat(depth) * 14)
    }
}

/// A picker row: highlighted under the pointer like a menu item, greyed when disabled.
private struct TreePickerRowStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 4)
            .foregroundStyle(isEnabled ? (hovered ? Color.white : Color.primary) : Color.secondary.opacity(0.6))
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(isEnabled && hovered ? Color.accentColor : Color.clear))
            .onHover { hovered = $0 }
    }
}

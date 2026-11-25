import AppKit
import SwiftUI
import Perception

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
    /// True: opening a branch closes the other branches of its level (the audio menu).
    var accordion = false
    /// False: the branches start folded unless they `startsOpen`, even with a ticked row under them.
    var opensCheckedBranches = true
    let onChoose: (String) -> Void
    let dismiss: () -> Void

    @State private var expanded: Set<String> = []
    /// Sections the hand folded or unfolded; absent = the section's own default.
    @State private var sectionOverrides: [String: Bool] = [:]
    @State private var seeded = false

    // `sections()` reads perceptible state (the audio watcher, the sidechain's view-model) in THIS body:
    // on macOS 12/13 that read is only tracked inside `WithPerceptionTracking`.
    var body: some View { WithPerceptionTracking { perceivedBody } }

    @ViewBuilder private var perceivedBody: some View {
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
        let s = TreePickerModel.seed(list, opensCheckedBranches: opensCheckedBranches)
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
                case .branch:
                    branchRow(n, depth: depth, siblings: list.filter { $0.role == .branch }.map(\.id))
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

    /// A branch: ONE button over the whole row that opens and closes what is under it, never chooses.
    private func branchRow(_ n: TreePickerNode, depth: Int, siblings: [String]) -> some View {
        Button {
            expanded = TreePickerModel.toggled(n.id, expanded: expanded, siblings: siblings, accordion: accordion)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: expanded.contains(n.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14)
                Text(verbatim: n.name)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                if let detail = n.detail {
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(TreePickerRowStyle())
        .padding(.leading, CGFloat(depth) * 14)
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

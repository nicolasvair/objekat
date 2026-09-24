import SwiftUI

/// The project-tabs strip (INC 1) — shown by `ContentView` only once there are two tabs or more
/// (@see `ContentView.body`): with a single project open it simply is not there, costing nothing
/// to look at.
struct WorkspaceTabBar: View {
    var workspace: Workspace

    private static let barHeight: CGFloat = 24

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(workspace.tabs) { tab in
                    TabCapsule(workspace: workspace, tab: tab)
                }

                Button {
                    _ = workspace.newTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .helpIf(L("tabs.new.help"))
            }
            .padding(.horizontal, 8)
        }
        .frame(height: Self.barHeight)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// One capsule of the strip: the project's name, a dot while modified, a ✕ on hover to close.
private struct TabCapsule: View {
    var workspace: Workspace
    var tab: WorkspaceTab

    @State private var hovering = false

    private var isActive: Bool { tab.id == workspace.activeTabID }

    var body: some View {
        Button {
            guard !isActive else { return }
            Task {
                if case .failure(.blocked(let reasonKey)) = await workspace.select(tab.id) {
                    workspace.session.viewModel.notify(L("tabs.switch.refused.title"), L(reasonKey))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(workspace.displayName(for: tab))
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if workspace.isDirty(for: tab) {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 5, height: 5)
                }

                // The close button takes the dirty dot's place on hover — the strip stays a fixed
                // width per tab rather than jumping as the mouse arrives.
                if hovering {
                    Button {
                        closeThisTab()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .helpIf(L("tabs.close.help"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Capsule()
                .fill(isActive ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
                               : Color.clear)
        )
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .onHover { hovering = $0 }
    }

    /// The same confirmation whether the tab clicked shut is the active one or not — only HOW to
    /// save differs: the active tab goes through the ordinary `save()`/`saveAs()`, an inactive one
    /// writes its PARKED document directly (`EditViewModel.writeDocument`) when it has a file, or —
    /// with none yet — is switched to so the user can "Save as" in the flesh (a panel cannot be
    /// driven for a tab that is not on screen).
    private func closeThisTab() {
        guard workspace.isDirty(for: tab) else {
            _ = workspace.close(tab.id, discard: false)
            return
        }
        let vm = workspace.session.viewModel
        switch vm.askDirtyDecision(titleKey: "dialog.dirty.title.closeTab",
                                   name: workspace.displayName(for: tab)) {
        case .cancel:
            return
        case .discard:
            _ = workspace.close(tab.id, discard: true)
        case .save:
            if isActive {
                if vm.projectURL != nil {
                    vm.save()
                    _ = workspace.close(tab.id, discard: true)
                } else {
                    vm.saveAs()
                }
            } else if let parked = tab.parked {
                if let url = parked.projectURL {
                    do {
                        try EditViewModel.writeDocument(parked.doc, to: url,
                                                        projectFolder: url.deletingLastPathComponent())
                        _ = workspace.close(tab.id, discard: true)
                    } catch {
                        vm.notify(L("tabs.saveTab.failed.title"), String(describing: error))
                    }
                } else {
                    Task { await workspace.select(tab.id) }
                }
            }
        }
    }
}

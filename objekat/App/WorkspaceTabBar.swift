import SwiftUI

/// The project-tabs strip (INC 1) — shown by `ContentView` only once there are two tabs or more
/// (@see `ContentView.body`): with a single project open it simply is not there, costing nothing
/// to look at.
struct WorkspaceTabBar: View {
    var workspace: Workspace

    private static let barHeight: CGFloat = 24
    private static let spacing: CGFloat = 4
    // `nonisolated`: read inside `onGeometryChange`'s `@Sendable` closure.
    private nonisolated static let coordinateSpaceName = "workspaceTabBar"

    // Reordering the strip by drag. `liveFrames` tracks every tab's X-range continuously, in the
    // strip's own coordinate space; a drag FREEZES the order and those frames on its first move
    // and is judged against that snapshot to the end (@see TabReorder — the neighbours move to
    // make room, so live frames would be compared against themselves). nil the rest of the time.
    @State private var liveFrames: [UUID: CGRect] = [:]
    @State private var drag: TabDrag?

    private struct TabDrag {
        let id: UUID
        let order: [UUID]
        let frames: [CGRect]
        var dx: CGFloat = 0

        var from: Int? { order.firstIndex(of: id) }
        var target: Int? { from.map { TabReorder.targetIndex(frames: frames, dragged: $0, dx: dx) } }

        /// The dragged tab follows the hand; a neighbour slides aside by `TabReorder.shift`.
        func offset(for tabID: UUID) -> CGFloat {
            if tabID == id { return dx }
            guard let from, let target, let index = order.firstIndex(of: tabID) else { return 0 }
            return TabReorder.shift(of: index, dragged: from, target: target,
                                    frames: frames, spacing: WorkspaceTabBar.spacing)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.spacing) {
                ForEach(workspace.tabs) { tab in
                    let isDragged = drag?.id == tab.id
                    let offset = drag?.offset(for: tab.id) ?? 0
                    TabCapsule(workspace: workspace, tab: tab)
                        .onGeometryChange(for: CGRect.self,
                                          of: { $0.frame(in: .named(Self.coordinateSpaceName)) }) { frame in
                            liveFrames[tab.id] = frame
                        }
                        .offset(x: offset)
                        // The neighbours glide aside; the dragged tab does NOT animate — it is
                        // under the hand, and an animation there would make it lag the pointer.
                        .animation(isDragged ? nil : Animation.easeOut(duration: 0.15), value: offset)
                        .zIndex(isDragged ? 1 : 0)
                        .gesture(tabDragGesture(for: tab))
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
            .coordinateSpace(.named(Self.coordinateSpaceName))
        }
        .frame(height: Self.barHeight)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Reordering the strip by drag

    /// `minimumDistance: 4` is what keeps the click: a hand that does not travel never starts the
    /// drag, so the capsule's tap (select) and its ✕ (close) answer exactly as before. The
    /// translation is read in the STRIP's coordinate space, which the dragged tab's own offset
    /// does not move — read in the tab's local space it would chase itself.
    private func tabDragGesture(for tab: WorkspaceTab) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                if drag?.id != tab.id {
                    let order = workspace.tabs.map(\.id)
                    drag = TabDrag(id: tab.id, order: order,
                                   frames: order.map { liveFrames[$0] ?? .zero })
                }
                drag?.dx = value.translation.width
            }
            .onEnded { _ in
                guard let current = drag, current.id == tab.id, let target = current.target else {
                    drag = nil
                    return
                }
                // ONE transaction for the reorder and the end of the drag: each neighbour's
                // layout position and its shift move by equal and opposite amounts (it stays
                // put), and the dragged tab glides from where it was let go into its slot. A
                // refused move (a switch under way) simply glides it back home.
                withAnimation(.easeOut(duration: 0.15)) {
                    workspace.moveTab(tab.id, to: target)
                    drag = nil
                }
            }
    }
}

/// One capsule of the strip: the project's name, a dot while modified, a ✕ on hover to close.
private struct TabCapsule: View {
    var workspace: Workspace
    var tab: WorkspaceTab

    @State private var hovering = false

    private var isActive: Bool { tab.id == workspace.activeTabID }

    // Content + `onTapGesture` rather than a `Button`, so the strip's reordering `DragGesture`
    // can share the view (@see WorkspaceTabBar.tabDragGesture) — the same reason
    // `StemStripButton` made the same change. The ✕ stays a real `Button`: a child's gesture
    // wins over its parent's tap.
    var body: some View {
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
        .onTapGesture {
            guard !isActive else { return }
            Task {
                if case .failure(.blocked(let reasonKey)) = await workspace.select(tab.id) {
                    workspace.session.viewModel.notify(L("tabs.switch.refused.title"), L(reasonKey))
                }
            }
        }
        .accessibilityAddTraits(.isButton)
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

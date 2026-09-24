import AppKit
import Foundation

/// Project tabs (INC 1) — ONE `ObjekatSession` (hence one `OBJEngineCore`, one `EditViewModel`),
/// several project documents taking turns being the active one. See
/// `project_multi_project_tabs_plan` (memory): a per-tab engine is off the table
/// (`OBJEngineCore`'s callbacks are `__unsafe_unretained` — a second instance, or tearing the one
/// there is down and rebuilding it, is exactly the crash that rule exists to prevent). A tab
/// switch is therefore always the same three moves: park the outgoing document
/// (`EditViewModel.parkProject()`), load the incoming one through the very door a project opening
/// uses (`applyProjectDocumentAsync`, non-cancellable), unpark what it carried.
///
/// `Workspace` owns the session and the tab list; `EditViewModel`/`ObjekatSession` know nothing
/// about tabs at all — `parkProject()`/`restoreParkedProject(_:)`/`tabSwitchBlocker` are the only
/// three points of contact, all on the view-model, because it alone knows what a document needs
/// carried between the file and the screen.
@MainActor
@Observable
final class Workspace {

    let session: ObjekatSession

    private(set) var tabs: [WorkspaceTab]
    private(set) var activeTabID: UUID

    /// True for the span of a tab switch / a new tab / an open into a new tab — the load itself
    /// already blocks the model (`isLoadingProject`), this additionally tells
    /// `Quiescence.inFlight()` (CommandAPI/Quiescence.swift) about the moment BETWEEN parking the
    /// outgoing tab and the incoming one's `applyProjectDocumentAsync` actually starting, where
    /// `isLoadingProject` is still false.
    private(set) var isSwitching = false

    enum TabError: Error, Equatable {
        /// A blocking operation is running — the associated value is an i18n key
        /// (`tabSwitchBlocker`'s), meant for `L(_:)`.
        case blocked(reasonKey: String)
        case dirty
        case lastTab
        case notFound
        case decodeFailed(String)
        case loadFailed
        case cancelled
    }

    struct OpenOutcome {
        let tabID: UUID
        let alreadyOpen: Bool
    }

    init() {
        session = ObjekatSession()
        let firstID = UUID()
        activeTabID = firstID
        tabs = [WorkspaceTab(id: firstID, parked: nil,
                             name: session.viewModel.projectName, url: nil, cachedDirty: false)]
        // `EditViewModel` knows nothing about tabs — this is the one wire crossing that boundary,
        // for `saveAs(to:)` alone (@see `EditViewModel.saveAsURLConflictCheck`).
        session.viewModel.saveAsURLConflictCheck = { [weak self] url in
            self?.isURLOpenElsewhere(url) ?? false
        }
    }

    // MARK: - Reading a tab (live for the active one, cached for a parked one)

    var activeTab: WorkspaceTab? { tabs.first { $0.id == activeTabID } }

    func displayName(for tab: WorkspaceTab) -> String {
        tab.id == activeTabID ? session.viewModel.projectName : (tab.parked?.projectName ?? tab.name)
    }

    func isDirty(for tab: WorkspaceTab) -> Bool {
        tab.id == activeTabID ? session.viewModel.isDirty : (tab.parked?.isDirty ?? tab.cachedDirty)
    }

    func url(for tab: WorkspaceTab) -> URL? {
        tab.id == activeTabID ? session.viewModel.projectURL : (tab.parked?.projectURL ?? tab.url)
    }

    /// True if `url` names the same file (by file-system identity, @see `FolderIdentity`) as a tab
    /// OTHER than the active one — the guard `EditViewModel.saveAs(to:)` asks through the hook it
    /// installs, since writing there from here would silently orphan whatever the other tab has in
    /// memory the next time it saves.
    func isURLOpenElsewhere(_ candidate: URL) -> Bool {
        guard let candidateID = FolderIdentity.identifier(candidate) else { return false }
        for tab in tabs where tab.id != activeTabID {
            guard let existing = url(for: tab), let existingID = FolderIdentity.identifier(existing)
            else { continue }
            if existingID.isEqual(candidateID) { return true }
        }
        return false
    }

    private func existingTab(for url: URL) -> WorkspaceTab? {
        guard let target = FolderIdentity.identifier(url) else { return nil }
        return tabs.first { tab in
            guard let existing = self.url(for: tab), let id = FolderIdentity.identifier(existing)
            else { return false }
            return id.isEqual(target)
        }
    }

    // MARK: - Switching

    /// Brings tab `id` to the front. A no-op returning success straight away if it already is.
    @discardableResult
    func select(_ id: UUID) async -> Result<Void, TabError> {
        guard id != activeTabID else { return .success(()) }
        guard tabs.contains(where: { $0.id == id }) else { return .failure(.notFound) }
        let vm = session.viewModel
        if let reason = vm.tabSwitchBlocker { return .failure(.blocked(reasonKey: reason)) }

        isSwitching = true
        defer { isSwitching = false }

        session.stop()
        vm.closeAllPluginEditors()

        let outgoingParked = vm.parkProject()
        if let outgoingIdx = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs[outgoingIdx].parked = outgoingParked
        }

        guard let targetIdx = tabs.firstIndex(where: { $0.id == id }),
              let targetParked = tabs[targetIdx].parked else {
            // Should not happen (every non-active tab always carries a `parked`), but a
            // model this defensive elsewhere should not go silent here.
            return .failure(.notFound)
        }
        await vm.restoreParkedProject(targetParked)
        tabs[targetIdx].parked = nil
        activeTabID = id
        return .success(())
    }

    /// A blank project in a NEW tab, made active straight away — the counterpart of
    /// `EditViewModel.newProject()` for a workspace of several tabs. Refused for the same reasons a
    /// switch is: the outgoing document is being torn down exactly as a switch tears it down.
    @discardableResult
    func newTab() -> Result<Void, TabError> {
        let vm = session.viewModel
        if let reason = vm.tabSwitchBlocker { return .failure(.blocked(reasonKey: reason)) }

        session.stop()
        vm.closeAllPluginEditors()

        let outgoingParked = vm.parkProject()
        if let outgoingIdx = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs[outgoingIdx].parked = outgoingParked
        }

        vm.newProjectDiscardingChanges()
        let newID = UUID()
        tabs.append(WorkspaceTab(id: newID, parked: nil, name: vm.projectName, url: nil,
                                 cachedDirty: false))
        activeTabID = newID
        return .success(())
    }

    /// Closes a tab. `discard` MUST be true to close one carrying unsaved changes — the caller
    /// (a menu action, the tab bar's ✕, or `tab.close`) is where a confirmation belongs, since only
    /// it knows whether it is driven by a hand that can answer a dialogue or a script that cannot.
    /// The last tab never closes (the app always shows exactly one project or more, never zero).
    @discardableResult
    func close(_ id: UUID, discard: Bool) -> Result<Void, TabError> {
        guard tabs.count > 1 else { return .failure(.lastTab) }
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }

        if id == activeTabID {
            let vm = session.viewModel
            guard discard || !vm.isDirty else { return .failure(.dirty) }
            if let reason = vm.tabSwitchBlocker { return .failure(.blocked(reasonKey: reason)) }
            // The neighbour: the tab right after, or the one before if this was the last —
            // whichever the array already keeps beside it.
            let neighbourIdx = idx + 1 < tabs.count ? idx + 1 : idx - 1
            let neighbourID = tabs[neighbourIdx].id
            session.stop()
            vm.closeAllPluginEditors()
            tabs.remove(at: idx)
            let refreshedIdx = tabs.firstIndex(where: { $0.id == neighbourID })!
            let targetParked = tabs[refreshedIdx].parked!
            // Synchronous from the caller's point of view is impossible here (the load breathes) —
            // callers of `close` on the ACTIVE tab must be prepared for the switch to land a beat
            // later; the menu/tab-bar await it exactly as `select` is awaited.
            Task { [weak self] in
                guard let self else { return }
                self.isSwitching = true
                await self.session.viewModel.restoreParkedProject(targetParked)
                if let i = self.tabs.firstIndex(where: { $0.id == neighbourID }) {
                    self.tabs[i].parked = nil
                }
                self.activeTabID = neighbourID
                self.isSwitching = false
            }
            return .success(())
        } else {
            guard let parked = tabs[idx].parked else { return .failure(.notFound) }
            guard discard || !parked.isDirty else { return .failure(.dirty) }
            tabs.remove(at: idx)
            return .success(())
        }
    }

    // MARK: - Opening a file

    /// Opens `url` — a duplicate of a tab already showing the SAME file (by file-system identity)
    /// switches to it rather than opening a second copy, `alreadyOpen` in the result saying so.
    /// Decodes BEFORE touching anything else: a malformed file must never disturb the tab already
    /// open (@see `EditViewModel.decodeProjectDocument(at:)`).
    /// - Parameter inNewTab: true opens a FRESH tab (a double-click in the Finder, `tab.open`);
    ///   false replaces the ACTIVE tab's document in place (the "Recent projects" menu, which kept
    ///   its historical one-tab-at-a-time meaning).
    @discardableResult
    func open(url: URL, inNewTab: Bool) async -> Result<OpenOutcome, TabError> {
        if let existing = existingTab(for: url) {
            if existing.id != activeTabID {
                if case .failure(let e) = await select(existing.id) { return .failure(e) }
            }
            return .success(OpenOutcome(tabID: existing.id, alreadyOpen: true))
        }

        let vm = session.viewModel
        let doc: ProjectDocument
        do {
            doc = try vm.decodeProjectDocument(at: url)
        } catch {
            return .failure(.decodeFailed(String(describing: error)))
        }
        let displayName = EditViewModel.projectDisplayName(for: url)

        if inNewTab {
            if let reason = vm.tabSwitchBlocker { return .failure(.blocked(reasonKey: reason)) }
            isSwitching = true
            session.stop()
            vm.closeAllPluginEditors()
            let outgoingParked = vm.parkProject()
            if let outgoingIdx = tabs.firstIndex(where: { $0.id == activeTabID }) {
                tabs[outgoingIdx].parked = outgoingParked
            }
            let ok = await vm.applyProjectDocumentAsync(doc, displayName: displayName, cancellable: false)
            isSwitching = false
            guard ok else { return .failure(.loadFailed) }
            vm.projectURL = url
            vm.projectName = displayName
            vm.isDirty = false
            vm.recordRecentProject(url)
            let newID = UUID()
            tabs.append(WorkspaceTab(id: newID, parked: nil, name: displayName, url: url,
                                     cachedDirty: false))
            activeTabID = newID
            return .success(OpenOutcome(tabID: newID, alreadyOpen: false))
        } else {
            guard vm.confirmDiscardIfDirty() else { return .failure(.cancelled) }
            let ok = await vm.applyProjectDocumentAsync(doc, displayName: displayName)
            guard ok else { return .failure(.loadFailed) }
            vm.projectURL = url
            vm.projectName = displayName
            vm.isDirty = false
            vm.recordRecentProject(url)
            return .success(OpenOutcome(tabID: activeTabID, alreadyOpen: false))
        }
    }

    /// The door "Ouvrir…" (Cmd+O) uses, once the panel has already handed back a URL: unlike
    /// `open(url:inNewTab:)`, opening the file the ACTIVE tab already has stays a plain reload (the
    /// historical behaviour of "Open" on your own file), and the load it runs stays CANCELLABLE —
    /// this is the one door in the whole family that still shows the overlay's Annuler button,
    /// because it is the one a user chose to run from a panel rather than a tab switch nobody asked
    /// to be interruptible.
    @discardableResult
    func replaceActive(with url: URL) async -> Result<Void, TabError> {
        if let existing = existingTab(for: url), existing.id != activeTabID {
            if case .failure(let e) = await select(existing.id) { return .failure(e) }
            return .success(())
        }
        let vm = session.viewModel
        guard vm.confirmDiscardIfDirty() else { return .failure(.cancelled) }
        let ok = await vm.loadProjectAsync(from: url)
        return ok ? .success(()) : .failure(.loadFailed)
    }

    // MARK: - Quitting

    /// `AppDelegate.applicationShouldTerminate`'s door: the active tab goes through the existing
    /// `confirmSaveBeforeQuit()` (unchanged), then every INACTIVE tab still carrying unsaved
    /// changes is asked about in turn, by NAME (`askDirtyDecision(titleKey:name:)`) since `self` —
    /// the one view-model — only knows the ACTIVE tab's own `projectName`.
    func confirmQuit() -> NSApplication.TerminateReply {
        let vm = session.viewModel
        guard !vm.isLoadingProject else { return .terminateCancel }
        guard vm.confirmSaveBeforeQuit() else { return .terminateCancel }

        for tab in tabs where tab.id != activeTabID {
            guard let parked = tab.parked, parked.isDirty else { continue }
            switch vm.askDirtyDecision(titleKey: "dialog.dirty.title.quit", name: parked.projectName) {
            case .discard:
                continue
            case .save:
                if let url = parked.projectURL {
                    do {
                        try EditViewModel.writeDocument(parked.doc, to: url,
                                                        projectFolder: url.deletingLastPathComponent())
                    } catch {
                        return .terminateCancel
                    }
                } else {
                    // No file yet: switching to it and opening "Save as" needs the run loop and a
                    // panel, neither available synchronously here — the quit is cancelled and the
                    // user finishes the save (now on screen) before asking to quit again.
                    let tabID = tab.id
                    Task { [weak self] in
                        guard let self else { return }
                        _ = await self.select(tabID)
                        self.session.viewModel.saveAs()
                    }
                    return .terminateCancel
                }
            case .cancel:
                return .terminateCancel
            }
        }
        return .terminateNow
    }
}

/// One entry of the workspace's tab strip. `parked` is nil FOR THE ACTIVE TAB ONLY (its state
/// lives directly in `Workspace.session.viewModel`); `name`/`url`/`cachedDirty` are the last known
/// values for a tab that has never been parked yet (freshly created) — read through
/// `Workspace.displayName(for:)`/`url(for:)`/`isDirty(for:)`, never directly, so the active tab's
/// entry is never stale.
struct WorkspaceTab: Identifiable {
    let id: UUID
    var parked: ParkedProject?
    var name: String
    var url: URL?
    var cachedDirty: Bool
}

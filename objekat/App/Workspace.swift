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
        /// true = a tab already held the file and it was RELOADED from disk (@see `reopen`). Always
        /// equal to `alreadyOpen` today; kept apart because they answer two questions — "was a
        /// tab created?" and "was the document in memory replaced?".
        var reloaded: Bool = false
    }

    /// Tabs INC2 (cross-project paste) — what `copySelected()` leaves behind is hoisted HERE, with
    /// the context that only survives as long as the tab it came from is the active one: which tab,
    /// the project's own folder (media/consolidated waves are never copied, they stay read from
    /// there — @see `EditViewModel.consolidateOriginFolders`) and the tempo (kept for completeness;
    /// `CrossProjectImport.plan` itself does NOT convert MIDI times by tempo, on purpose — musical
    /// beats travel as-is). Captured EAGERLY, at copy time, because `EditViewModel.clipboard` is a
    /// single field shared by every tab (there is only one `EditViewModel` — @see the file header):
    /// by the time a paste lands in a DIFFERENT tab, that field's own `consolidateID`s would no
    /// longer resolve against `session.viewModel.consolidateDefinitions`, which has since become
    /// the TARGET project's own dictionary.
    private struct CrossProjectClipboardRecord {
        let originTabID: UUID
        let originTempo: Double
        let clipboard: CrossProjectImport.Clipboard
    }
    private var crossProjectClipboard: CrossProjectClipboardRecord?

    init() {
        session = ObjekatSession()
        let firstID = UUID()
        activeTabID = firstID
        tabs = [WorkspaceTab(id: firstID, parked: nil,
                             name: session.viewModel.projectName, url: nil, cachedDirty: false)]
        // `EditViewModel` knows nothing about tabs — these are the wires crossing that boundary:
        // `saveAsURLConflictCheck` (INC1) for `saveAs(to:)`, and the two INC2 clipboard hooks below.
        session.viewModel.saveAsURLConflictCheck = { [weak self] url in
            self?.isURLOpenElsewhere(url) ?? false
        }
        session.viewModel.clipboardDidChangeHook = { [weak self] in
            self?.captureCrossProjectClipboard()
        }
        session.viewModel.crossProjectPasteHook = { [weak self] in
            self?.attemptCrossProjectPaste() ?? false
        }
    }

    /// `EditViewModel.clipboardDidChangeHook`: freezes the clipboard `copySelected()` just set,
    /// alongside the origin context above. A no-op if the copy somehow left no clipboard behind
    /// (should not happen — `copySelected()` calls the hook only after setting one — kept as a
    /// guard rather than an assumption).
    private func captureCrossProjectClipboard() {
        let vm = session.viewModel
        guard let cb = vm.clipboard else { return }
        // An unsaved project has no folder yet: a cross-project paste of a plain clip still works
        // (its `filePath` is already absolute), only a CONSOLIDATED object's media could fail to
        // resolve on the far side — an accepted, narrow edge case rather than a reason to refuse
        // the copy outright.
        let folder = vm.projectFolder ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let clipboard = CrossProjectImport.Clipboard(
            clips: cb.clips,
            comments: cb.comments,
            consolidateDefinitions: vm.consolidateDefinitions,
            fxLinks: Dictionary(uniqueKeysWithValues:
                vm.fxLinksForPersistence(items: cb.clips, stems: []).map { ($0.id, $0) }),
            originFolder: folder,
            originTime: cb.originTime,
            originLane: cb.originLane)
        crossProjectClipboard = CrossProjectClipboardRecord(originTabID: activeTabID,
                                                            originTempo: vm.tempo,
                                                            clipboard: clipboard)
    }

    /// `EditViewModel.crossProjectPasteHook`: declines (`false`) whenever there is nothing hoisted
    /// yet, OR the active tab IS the clipboard's own origin — the ordinary, same-tab paste, which
    /// must go on being handled by `paste()` itself, unchanged. Only a genuine cross-tab paste
    /// takes this branch, and it fully replaces `paste()`'s own body for that call.
    private func attemptCrossProjectPaste() -> Bool {
        guard let record = crossProjectClipboard, record.originTabID != activeTabID else { return false }
        session.viewModel.pasteCrossProjectPlan(record.clipboard)
        return true
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
        isURLOpen(candidate, inTabOtherThan: activeTabID)
    }

    /// The same question asked on behalf of ANY tab — the Save As a closing PARKED tab owes
    /// (`settleUnsavedChanges`) must not land on a file the active tab, or a third one, holds.
    private func isURLOpen(_ candidate: URL, inTabOtherThan excluded: UUID) -> Bool {
        guard let candidateID = FolderIdentity.identifier(candidate) else { return false }
        for tab in tabs where tab.id != excluded {
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

    // MARK: - Reordering

    /// Moves tab `id` so that it ends up at 0-based `destination` in `tabs` (clamped to the
    /// strip's bounds) — the tab bar's drag and `tab.move` both come through here, and nothing
    /// else changes: the ACTIVE tab stays the active one (it is named by id, never by position),
    /// no document is parked or loaded, the engine is not told. Everything that reads a tab BY
    /// POSITION — ⌘1…9, ⌃⇥ / ⌃⇧⇥, `tab.select {index}` — reads `tabs` at the moment it is used,
    /// so it follows the new order with nothing to update.
    ///
    /// Refused while a switch is under way, and that is not caution for its own sake: `select`
    /// resolves the target's INDEX before its `await` and writes through it afterwards, so a
    /// reorder landing inside that await would hand the incoming tab's `parked = nil` to
    /// whichever tab had slid into the slot. The export / render / consolidate-edit blockers are
    /// NOT consulted — a reorder touches no document, so there is nothing for them to protect.
    @discardableResult
    func moveTab(_ id: UUID, to destination: Int) -> Result<Void, TabError> {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }
        if isSwitching { return .failure(.blocked(reasonKey: "tabs.switch.refused.loading")) }
        let to = max(0, min(tabs.count - 1, destination))
        guard to != from else { return .success(()) }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        return .success(())
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
        // Les plugins de l'onglet qu'on quitte restent vivants jusqu'à son retour ou sa fermeture
        // (@see -[OBJEngineCore beginHoldingParkedPluginsForTab:]) ; ceux de la cible sont repris.
        vm.engine?.beginHoldingParkedPlugins(forTab: activeTabID.uuidString)
        await vm.restoreParkedProject(targetParked)
        vm.engine?.endHoldingParkedPlugins()
        vm.engine?.expireParkedPlugins(forTab: id.uuidString)
        // Looked up AGAIN, never through `targetIdx`: the strip is not frozen during the await
        // (a ✕ on another tab, a reorder), and an index read before it could name another tab
        // by now — whose parked document this line would then throw away.
        if let i = tabs.firstIndex(where: { $0.id == id }) {
            tabs[i].parked = nil
        }
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

        vm.engine?.beginHoldingParkedPlugins(forTab: activeTabID.uuidString)
        vm.newProjectDiscardingChanges()
        vm.engine?.endHoldingParkedPlugins()
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
        // Not while a switch is under way, for `moveTab`'s reason: the switch holds tabs it is
        // about to write back, and a tab taken out from under it would leave `activeTabID`
        // naming nothing.
        if isSwitching { return .failure(.blocked(reasonKey: "tabs.switch.refused.loading")) }
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
                self.session.viewModel.engine?.expireParkedPlugins(forTab: neighbourID.uuidString)
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
            session.viewModel.engine?.releaseParkedPlugins(forTab: id.uuidString)
            return .success(())
        }
    }

    // MARK: - Opening a file

    /// Opens `url`. A file a tab ALREADY holds (by file-system identity) is never opened twice:
    /// that tab is brought forward and RELOADED from disk (@see `reopen`), `alreadyOpen` and
    /// `reloaded` in the result saying so.
    /// Decodes BEFORE touching anything else: a malformed file must never disturb the tab already
    /// open (@see `EditViewModel.decodeProjectDocument(at:)`).
    /// - Parameter inNewTab: true opens a FRESH tab (a double-click in the Finder, `tab.open`);
    ///   false replaces the ACTIVE tab's document in place (the "Recent projects" menu, which kept
    ///   its historical one-tab-at-a-time meaning).
    /// - Parameter pluginIDRepair: what to do about plugin ids duplicated across hosts, settled
    ///   BEFORE anything is parked or torn down (@see `EditViewModel.resolvePluginIDRepair`): `.ask`
    ///   for a hand (the default), `.repair` / `.keep` for a script.
    /// - Parameter requester: who answers the unsaved-changes question if the file is already
    ///   open and modified — a hand (the dialogue) or a script (`discard`, @see ReopenSameFile).
    @discardableResult
    func open(url: URL, inNewTab: Bool,
              pluginIDRepair: PluginIDRepairChoice = .ask,
              requester: ReopenSameFile.Requester = .hand) async -> Result<OpenOutcome, TabError> {
        if let existing = existingTab(for: url) {
            return await reopen(existing, from: url, requester: requester,
                                pluginIDRepair: pluginIDRepair)
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
            // Asked BEFORE the current tab is parked: a question put after would sit over a window
            // already half taken apart, and a "no" would have nothing to go back to.
            let repair = vm.resolvePluginIDRepair(pluginIDRepair, doc: doc, url: url)
            isSwitching = true
            session.stop()
            vm.closeAllPluginEditors()
            let outgoingParked = vm.parkProject()
            if let outgoingIdx = tabs.firstIndex(where: { $0.id == activeTabID }) {
                tabs[outgoingIdx].parked = outgoingParked
            }
            vm.engine?.beginHoldingParkedPlugins(forTab: activeTabID.uuidString)
            let ok = await vm.applyProjectDocumentAsync(doc, displayName: displayName, cancellable: false,
                                                        repairPluginIDs: repair)
            vm.engine?.endHoldingParkedPlugins()
            isSwitching = false
            guard ok else { return .failure(.loadFailed) }
            vm.lastProjectLoad?.path = url.path
            vm.projectURL = url
            vm.projectName = displayName
            vm.settleDirtyAfterLoad()   // clean, unless the load re-keyed plugin ids
            vm.recordRecentProject(url)
            let newID = UUID()
            tabs.append(WorkspaceTab(id: newID, parked: nil, name: displayName, url: url,
                                     cachedDirty: vm.isDirty))
            activeTabID = newID
            return .success(OpenOutcome(tabID: newID, alreadyOpen: false))
        } else {
            // Replacing the active document tears its Edit down, and a direct render is reading it.
            if vm.exportPinsActiveDocument {
                vm.refuseWhileExportPins()   // the menu ignores the failure: this is its only voice
                return .failure(.blocked(reasonKey: "tabs.switch.refused.export"))
            }
            guard vm.confirmDiscardIfDirty() else { return .failure(.cancelled) }
            let repair = vm.resolvePluginIDRepair(pluginIDRepair, doc: doc, url: url)
            let ok = await vm.applyProjectDocumentAsync(doc, displayName: displayName,
                                                        repairPluginIDs: repair)
            guard ok else { return .failure(.loadFailed) }
            vm.lastProjectLoad?.path = url.path
            vm.projectURL = url
            vm.projectName = displayName
            vm.settleDirtyAfterLoad()   // clean, unless the load re-keyed plugin ids
            vm.recordRecentProject(url)
            return .success(OpenOutcome(tabID: activeTabID, alreadyOpen: false))
        }
    }

    /// The door "Ouvrir…" (Cmd+O) uses, once the panel has already handed back a URL. A file a tab
    /// already holds — this one or another — is RELOADED in that tab, exactly as every other door
    /// does it (@see `reopen`). Any other file replaces the active document through a load that
    /// stays CANCELLABLE — the one door in the whole family that still shows the overlay's Annuler
    /// button, because it is the one a user chose to run from a panel rather than a tab switch
    /// nobody asked to be interruptible.
    @discardableResult
    func replaceActive(with url: URL) async -> Result<Void, TabError> {
        if let existing = existingTab(for: url) {
            switch await reopen(existing, from: url, requester: .hand) {
            case .success:            return .success(())
            case .failure(let error): return .failure(error)
            }
        }
        let vm = session.viewModel
        if vm.exportPinsActiveDocument {
            vm.refuseWhileExportPins()
            return .failure(.blocked(reasonKey: "tabs.switch.refused.export"))
        }
        guard vm.confirmDiscardIfDirty() else { return .failure(.cancelled) }
        let ok = await vm.loadProjectAsync(from: url)
        return ok ? .success(()) : .failure(.loadFailed)
    }

    // MARK: - Re-opening a file a tab already holds

    /// Opening a file a tab ALREADY holds RELOADS it from disk, into that tab — it is how one goes
    /// back to the state of the last save after a mistake. One door for every road in (the menu's
    /// Open…, a recent project, the Finder / the Dock, `tab.open`), so they all behave alike.
    ///
    /// The decision is `ReopenSameFile.decide` (pure, asserted alone): refused while a load, a
    /// direct export, a render or a consolidated edit is under way (the reasons a switch is
    /// refused — a reload tears the document down exactly as a switch does); a CLEAN tab reloads
    /// with no question (nothing a hand made can be lost, the screen already shows what is on
    /// disk); a MODIFIED one asks the close/quit question first (Save / Don't Save / Cancel, under
    /// a title of its own) — or, for a script, needs `discard`.
    ///
    /// The tab holding the file is brought forward FIRST if it is not the active one, and the
    /// question is asked once it is on screen: what one is about to throw away is then what one is
    /// looking at. Cancel leaves the hand on that tab, which is what opening it used to do. A
    /// script's refusals are decided BEFORE the switch, so a refused `tab.open` moves nothing.
    ///
    /// The reload itself is an ordinary opening — `applyProjectDocumentAsync`, so the bulk-load
    /// inhibitor, the plugin consigne (an AU whose state did not move is taken back, not
    /// re-instantiated) and the viewport saved in the file all behave as at any opening — with
    /// three choices of its own:
    /// - NOT cancellable: a reload cancelled half-way would leave the tab on an EMPTY project
    ///   (@see `runProjectLoadAsync`), and a tab's document should never vanish under a revert;
    /// - the undo/redo history STARTS OVER, as at any opening: the stacks hold snapshots of the
    ///   state being thrown away, and an undo that brought it back would be a second, hidden way
    ///   of not reverting;
    /// - "Save" in the question writes the tab, then reloads what was just written — the same
    ///   state, with the history reset. It is offered because the question is the one a close asks
    ///   (the user asked for the same options), not because it is the useful answer here.
    @discardableResult
    func reopen(_ existing: WorkspaceTab, from url: URL,
                requester: ReopenSameFile.Requester,
                pluginIDRepair: PluginIDRepairChoice = .ask) async -> Result<OpenOutcome, TabError> {
        let vm = session.viewModel
        let blocker = vm.tabSwitchBlocker ?? (isSwitching ? "tabs.switch.refused.loading" : nil)
        switch ReopenSameFile.decide(blocker: blocker, isDirty: isDirty(for: existing),
                                     requester: requester) {
        case .refuse(let reasonKey):
            guard requester == .hand else { return .failure(.blocked(reasonKey: reasonKey)) }
            // A hand gets its refusal SAID, in a reload's own words (the callers that reach here
            // by hand — a menu, the Finder — have nothing else to show it with); `.cancelled`
            // then keeps them from saying it a second time.
            vm.notify(L("project.reload.refused.title"),
                      L(ReopenSameFile.reloadRefusalKey(forBlocker: reasonKey)))
            return .failure(.cancelled)
        case .refuseDirty:
            return .failure(.dirty)
        case .reload, .askThenReload:
            break
        }

        if existing.id != activeTabID {
            if case .failure(let e) = await select(existing.id) { return .failure(e) }
        }
        // Asked on the tab now in front: its own name, its own LIVE dirty flag. A no-op on a clean
        // tab; under an automatic dialogue policy it answers by itself (@see askDirtyDecision).
        if requester == .hand {
            guard vm.confirmDiscardIfDirty(titleKey: "dialog.dirty.title.reload",
                                           infoKey: "dialog.dirty.info.reload")
            else { return .failure(.cancelled) }
        }

        // Decoded only now — after a "Save", the file IS what was just written — and before
        // anything is torn down: a file gone bad on disk leaves the tab exactly as it was.
        let doc: ProjectDocument
        do {
            doc = try vm.decodeProjectDocument(at: url)
        } catch {
            return .failure(.decodeFailed(String(describing: error)))
        }
        let displayName = EditViewModel.projectDisplayName(for: url)
        // Settled before the teardown, as at any opening: the file may carry duplicated plugin ids.
        let repair = vm.resolvePluginIDRepair(pluginIDRepair, doc: doc, url: url)

        isSwitching = true
        session.stop()
        vm.closeAllPluginEditors()
        let ok = await vm.applyProjectDocumentAsync(doc, displayName: displayName, cancellable: false,
                                                    repairPluginIDs: repair)
        isSwitching = false
        vm.lastProjectLoad?.path = url.path
        guard ok else { return .failure(.loadFailed) }
        vm.projectURL = url
        vm.projectName = displayName
        vm.clearObjectBoundTransientState()
        vm.settleDirtyAfterLoad()   // clean, unless the load re-keyed plugin ids
        vm.recordRecentProject(url)
        NSLog("[TABS] reloaded from disk: %@", url.lastPathComponent)
        return .success(OpenOutcome(tabID: activeTabID, alreadyOpen: true, reloaded: true))
    }

    // MARK: - Opening from outside the app

    /// Sessions handed over from OUTSIDE (a double-click in the Finder, a file dropped on the Dock
    /// icon, `open -a`), waiting their turn. A queue and not a `Task` per file: the Finder hands
    /// over a multiple selection in one go, and two loads started side by side would have the
    /// second refused by the first (`tabSwitchBlocker` — a project loading). One at a time, in the
    /// order given. `@ObservationIgnored`: nothing draws it, and an observed queue would invalidate
    /// the tab bar at every file for nothing.
    @ObservationIgnored private var outsideOpenQueue: [URL] = []
    @ObservationIgnored private var isDrainingOutsideOpens = false
    /// The file being opened from outside right now (nil between two), and when the last one
    /// ended — @see `openFromOutside` for why a second arrival of the same file is dropped.
    @ObservationIgnored private var outsideOpenInFlight: URL?
    @ObservationIgnored private var lastOutsideOpen: (url: URL, endedAt: Date)?

    /// The door `AppDelegate.application(_:open:)` and the window's `onOpenURL` both go through —
    /// both, because which of the two SwiftUI actually calls for a document handed over by the
    /// Finder is not something this code can settle by reading (@see the AppDelegate). A file
    /// already queued is not queued twice. And since re-opening a file a tab already holds now
    /// RELOADS it (@see `reopen`), one that arrives by both roads must not be opened a second
    /// time either: the same file arriving while it is being opened, or within a moment of it,
    /// is the same double-click, not a request to revert — a heavy project would otherwise load
    /// twice for one gesture.
    func openFromOutside(_ urls: [URL]) {
        for url in urls.map(\.standardizedFileURL) where !outsideOpenQueue.contains(url) {
            if url == outsideOpenInFlight { continue }
            if let last = lastOutsideOpen, last.url == url,
               Date().timeIntervalSince(last.endedAt) < Self.outsideOpenEchoWindow { continue }
            outsideOpenQueue.append(url)
        }
        guard !isDrainingOutsideOpens, !outsideOpenQueue.isEmpty else { return }
        isDrainingOutsideOpens = true
        Task { [weak self] in
            guard let self else { return }
            while !self.outsideOpenQueue.isEmpty {
                let url = self.outsideOpenQueue.removeFirst()
                self.outsideOpenInFlight = url
                await self.openOneFromOutside(url)
                self.outsideOpenInFlight = nil
                self.lastOutsideOpen = (url, Date())
            }
            self.isDrainingOutsideOpens = false
        }
    }

    /// How long after an opening from outside the same file arriving again is taken for an echo of
    /// it (the second road) rather than for a new double-click. Short on purpose: a hand that
    /// double-clicks the file again to revert does so seconds later, not within this.
    private static let outsideOpenEchoWindow: TimeInterval = 1.5

    /// One session from outside. The rules are `open(url:inNewTab:)`'s — the same file is never
    /// opened twice (a tab already holding it is brought forward and reloaded), and a new tab is what a
    /// double-click means — with ONE exception: an untouched "Untitled" tab (no file, not
    /// modified, empty) is REUSED rather than left behind. That is the ordinary case of a cold
    /// launch by a double-click (the app starts on a blank project, then the file arrives), and a
    /// blank tab beside every project opened that way would be one more thing to close by hand.
    /// Every refusal and failure is SAID (`notify`): nobody asked this from a menu that could grey
    /// itself out, the hand is in the Finder and would otherwise see nothing happen.
    private func openOneFromOutside(_ url: URL) async {
        let vm = session.viewModel
        // At a cold launch the file can arrive before the window's `onAppear` has wired the engine
        // to the document (@see ContentView) — a load with no engine attached lays a model nothing
        // plays. `start()` is idempotent, so calling it here costs nothing the second time.
        session.start()
        guard FileManager.default.fileExists(atPath: url.path) else {
            vm.notify(L("project.notFound.title"), L("project.notFound.info", url.lastPathComponent))
            return
        }
        // The in-place path of `open(url:inNewTab: false)` has no guard of its own (the menus that
        // reach it are greyed out while busy); this door is not a menu, so it asks here. Not for a
        // file a tab already holds: that is a RELOAD, which says its own refusal in its own words
        // (@see `reopen`) — or, for another tab's file, the switch's refusal comes back below.
        let alreadyHeld = existingTab(for: url) != nil
        if !alreadyHeld, let reason = vm.tabSwitchBlocker {
            vm.notify(L("tabs.switch.refused.title"), L(reason))
            return
        }
        let untouched = vm.projectURL == nil && !vm.isDirty && vm.items.isEmpty
        switch await open(url: url, inNewTab: !untouched) {
        case .success, .failure(.cancelled):
            return
        case .failure(.loadFailed):
            // In place (`untouched`), false means ONE thing: a load the hand cancelled from the
            // overlay (that path stays cancellable) — a decision, not a failure. In a NEW tab the
            // load is not cancellable, so false there is a real failure, and it is said — and so
            // is a RELOAD's, which is not cancellable either.
            if !untouched || alreadyHeld {
                vm.notify(L("project.openFailed.title"), L("project.openFailed.info", url.lastPathComponent))
            }
        case .failure(.blocked(let reasonKey)):
            vm.notify(L("tabs.switch.refused.title"), L(reasonKey))
        case .failure:
            // `.decodeFailed` above all: a file with the right extension and the wrong content.
            vm.notify(L("project.openFailed.title"), L("project.openFailed.info", url.lastPathComponent))
        }
    }

    // MARK: - Unsaved changes: closing a tab, quitting

    /// THE question a tab carrying unsaved changes is asked before it goes away. ⌘W, the strip's
    /// ✕ and ⌘Q all come through here, so the three show ONE dialogue — the project's name, and
    /// Save / Don't Save / Cancel, `askDirtyDecision`'s own — where there were three hand-written
    /// copies of it, each saving its own way.
    ///
    /// true = the tab may go: it was clean, it was saved, or its changes were explicitly thrown
    /// away. false = it stays: Cancel, a Save As panel dismissed, or a write that FAILED — the
    /// paths this replaced read a failed write as a green light (`save()` swallows the error) and
    /// closed the tab, or quit, behind it.
    ///
    /// Synchronous on purpose, the Save As panel included (run MODALLY, where the menu's own
    /// `saveAs()` uses `begin`): `applicationShouldTerminate` needs its answer now, and a tab that
    /// has not been switched to never has to be — the panel writes the PARKED document, so a quit
    /// no longer has to cancel itself, bring an untitled tab to the front and wait for a second ⌘Q.
    ///
    /// Never reaches a panel without a hand: under `dialogPolicy` ≠ `.ask` the question answers
    /// "don't save" or "cancel" by itself, and `hasInterface` guards the panel besides. The API's
    /// `tab.close` does not come here at all — its `discard` contract stays the script's own.
    func settleUnsavedChanges(of id: UUID, titleKey: String) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), isDirty(for: tab) else { return true }
        let name = displayName(for: tab)
        switch session.viewModel.askDirtyDecision(titleKey: titleKey, name: name) {
        case .cancel:  return false
        case .discard: return true
        case .save:    return saveBeforeLeaving(id, name: name)
        }
    }

    /// The "Save" half of `settleUnsavedChanges`, for the active tab (the ordinary `writeSession`)
    /// as for a parked one (its document written as it was parked). A tab with no file yet goes
    /// through Save As — same panel, same naming rule, same refusal to land on a file another tab
    /// holds as the menu's. Every failure is SAID, since the answer false keeps a tab open, or
    /// the app running, that the hand had just asked to close.
    private func saveBeforeLeaving(_ id: UUID, name: String) -> Bool {
        let vm = session.viewModel
        let isActive = id == activeTabID
        let knownURL = isActive ? vm.projectURL : tabs.first(where: { $0.id == id })?.parked?.projectURL
        let target: URL
        if let knownURL {
            target = knownURL
        } else {
            guard vm.hasInterface else { return false }
            let panel = EditViewModel.makeSaveAsPanel(projectURL: nil, projectName: name,
                                                      startingAt: vm.saveAsStartFolder(for: nil))
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            target = EditViewModel.saveAsFileURL(for: chosen)
            if isURLOpen(target, inTabOtherThan: id) {
                vm.notify(L("tabs.saveAs.alreadyOpen.title"), L("tabs.saveAs.alreadyOpen.message"))
                return false
            }
        }
        let written = isActive ? vm.writeSession(to: target) : writeParkedTab(id, to: target)
        if !written {
            vm.notify(L("tabs.saveTab.failed.title"), L("dialog.dirty.saveFailed.info", name))
        }
        return written
    }

    /// Writes a PARKED tab's document to `fileURL` and brings its parked state up to date (file,
    /// name, clean) — so a quit cancelled at a LATER tab's question leaves this one showing what
    /// is really on disk, and the next question about it is not asked for nothing. The paths are
    /// made portable against the destination folder, exactly as `writeSession` writes the active
    /// tab's: the parked document keeps the model's absolute paths, and a file written with them
    /// would break the day its folder moved.
    private func writeParkedTab(_ id: UUID, to fileURL: URL) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }), let parked = tabs[idx].parked
        else { return false }
        let vm = session.viewModel
        let folder = fileURL.deletingLastPathComponent()
        var doc = parked.doc
        doc.items = vm.portableItems(doc.items, projectFolder: folder)
        do {
            try EditViewModel.writeDocument(doc, to: fileURL, projectFolder: folder)
        } catch {
            return false
        }
        tabs[idx].parked?.projectURL = fileURL
        tabs[idx].parked?.projectName = EditViewModel.projectDisplayName(for: fileURL)
        tabs[idx].parked?.isDirty = false
        vm.recordRecentProject(fileURL)
        return true
    }

    /// Closing a tab by HAND — ⌘W and the strip's ✕, one door. A switch that would be refused is
    /// said BEFORE the question rather than after it: asking, saving, then finding the tab cannot
    /// close after all (an export running) would leave the hand wondering what its answer did.
    func closeWithConfirmation(_ id: UUID) {
        let vm = session.viewModel
        if isSwitching {
            vm.notify(L("tabs.switch.refused.title"), L("tabs.switch.refused.loading"))
            return
        }
        if id == activeTabID, let reason = vm.tabSwitchBlocker {
            vm.notify(L("tabs.switch.refused.title"), L(reason))
            return
        }
        guard settleUnsavedChanges(of: id, titleKey: "dialog.dirty.title.closeTab") else { return }
        _ = close(id, discard: true)
    }

    /// `AppDelegate.applicationShouldTerminate`'s door: EVERY tab carrying unsaved changes is
    /// asked about in turn — the one on screen first, then the others in the strip's order, each
    /// by NAME since only one of them is on screen. Cancel at any question, or a save that did not
    /// happen, and nothing quits; the tabs already saved on the way stay saved.
    func confirmQuit() -> NSApplication.TerminateReply {
        guard !session.viewModel.isLoadingProject, !isSwitching else { return .terminateCancel }
        let order = [activeTabID] + tabs.map(\.id).filter { $0 != activeTabID }
        for id in order {
            guard settleUnsavedChanges(of: id, titleKey: "dialog.dirty.title.quit") else {
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

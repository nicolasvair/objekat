import AppKit
import UniformTypeIdentifiers

extension EditViewModel {

    // MARK: - Recent projects

    private static let recentProjectsKey = "recentProjects"
    private static let recentProjectsMax = 10

    /// `--no-recent`: this launch does NOT TOUCH the persisted list. It still reads it (the
    /// sub-menu stays usable for opening a real project), but nothing it opens or
    /// saves goes into it, and no write goes out to `UserDefaults`. That is what lets
    /// a test open twenty throwaway projects without chasing the real projects out of the list.
    static var recordsRecentProjects: Bool { !LaunchArguments.process.noRecentProjects }

    static func loadRecentProjects() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: recentProjectsKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// Inserts the URL at the head (de-duplicated by path), truncates to 10, persists.
    /// No effect under `--no-recent` (@see `recordsRecentProjects`).
    func recordRecentProject(_ url: URL) {
        guard Self.recordsRecentProjects else { return }
        let path = url.standardizedFileURL.path
        var list = recentProjects.filter { $0.standardizedFileURL.path != path }
        list.insert(url.standardizedFileURL, at: 0)
        if list.count > Self.recentProjectsMax {
            list = Array(list.prefix(Self.recentProjectsMax))
        }
        recentProjects = list
        persistRecentProjects()
    }

    func clearRecentProjects() {
        recentProjects = []
        persistRecentProjects()
    }

    /// Removes an entry (e.g. a file that cannot be found) without touching the rest.
    private func removeRecentProject(_ url: URL) {
        let path = url.standardizedFileURL.path
        recentProjects.removeAll { $0.standardizedFileURL.path == path }
        persistRecentProjects()
    }

    private func persistRecentProjects() {
        // The last lock before `UserDefaults`: under `--no-recent` the list lives in memory for
        // the length of the session (removing a dead entry, "Clear") and the user's
        // setting comes back intact on the next launch.
        guard Self.recordsRecentProjects else { return }
        let paths = recentProjects.map { $0.path }
        UserDefaults.standard.set(paths, forKey: Self.recentProjectsKey)
    }

    /// Opens a recent project from the menu: confirms any loss,
    /// purges the entry and alerts if the file has gone.
    func openRecentProject(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            removeRecentProject(url)
            notify(L("project.notFound.title"),
                   L("project.notFound.info", url.lastPathComponent))
            return
        }
        guard confirmDiscardIfDirty() else { return }
        loadProject(from: url)
    }

    /// The breathing twin of `openRecentProject(_:)` — the menu's own entry point, so the overlay
    /// shows for a recent project exactly as it does for a freshly browsed one.
    func openRecentProjectAsync(_ url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else {
            removeRecentProject(url)
            notify(L("project.notFound.title"),
                   L("project.notFound.info", url.lastPathComponent))
            return
        }
        guard confirmDiscardIfDirty() else { return }
        await loadProjectAsync(from: url)
    }

    // MARK: - Saving / loading a project

    /// The current project folder: the parent of the active version file.
    var projectFolder: URL? { projectURL?.deletingLastPathComponent() }

    /// The project's `waveforms/` folder (nil as long as the project has not been saved).
    var waveformsFolder: URL? { projectFolder.map { waveformsDir(in: $0) } }

    private static func waveformsDir(in folder: URL) -> URL {
        folder.appendingPathComponent("waveforms", isDirectory: true)
    }
    private static func samplesDir(in folder: URL) -> URL {
        folder.appendingPathComponent("samples", isDirectory: true)
    }
    private func waveformsDir(in folder: URL) -> URL { Self.waveformsDir(in: folder) }
    private func samplesDir(in folder: URL) -> URL { Self.samplesDir(in: folder) }

    /// The display name of a version file: strips the manifest's extension.
    private func displayName(for fileURL: URL) -> String {
        Self.projectDisplayName(for: fileURL)
    }

    /// The NAME of a project as it is shown and typed: with no ".json" — the extension is an
    /// internal matter of the manifest, never something the user names. Strips THAT suffix and
    /// no other, in particular never a path extension of its own making: "Mix 1.2" is a name,
    /// not a file with a ".2" extension.
    /// Shared by the window title, the panel and the "Recent projects" menu, so that one
    /// project has one name everywhere.
    static func projectDisplayName(for url: URL) -> String {
        let name = url.lastPathComponent
        guard name.hasSuffix(".json") else { return name }
        let base = String(name.dropLast(".json".count))
        return base.isEmpty ? name : base
    }

    /// Saves into the active version if there is one, otherwise "Save as".
    /// It writes where it read, and does not rename a file under the user's feet.
    func save() {
        if let url = projectURL {
            writeSession(to: url)
        } else {
            saveAs()
        }
    }

    /// Save as: the user chooses the NAME + the location of the project.
    /// A project is a FOLDER, so what is typed here is a plain name — "My Project", never
    /// "My Project.objekat": no content type is imposed on the panel, and the ".json" of the
    /// manifest is laid by `saveAs(to:)`, which is the only one to know about it.
    /// If the destination is already an Objekat project folder → only the JSON is written there
    /// (several versions can live side by side, sharing samples/ and waveforms/).
    /// Otherwise → a project folder named after what was typed is created and written into.
    func saveAs() {
        let panel = Self.makeSaveAsPanel(projectURL: projectURL, projectName: projectName)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let chosen = panel.url else { return }
            // The panel is sent away FIRST: as long as it is on screen the document window is not
            // "main" any more, and the title the save lays would land nowhere (@see
            // updateWindowTitle).
            panel.orderOut(nil)
            saveAs(to: chosen)
            updateWindowTitle()
        }
    }

    /// The heart of "Save as", without AppKit: this is where an existing project folder or a
    /// folder to create gets decided. Separated from the panel so that external driving takes
    /// EXACTLY the same path as the menu — a single naming rule, so no drift is
    /// possible between what the interface does and what a script does.
    @discardableResult
    func saveAs(to chosen: URL) -> Bool {
        let fileURL = Self.saveAsFileURL(for: chosen)
        // Tabs (INC1): writing over a file another tab already has open would silently orphan
        // whatever that tab still holds in memory the next time IT saves — refused here, before a
        // single byte is written, rather than diagnosed after the fact.
        if saveAsURLConflictCheck?(fileURL) == true {
            notify(L("tabs.saveAs.alreadyOpen.title"), L("tabs.saveAs.alreadyOpen.message"))
            return false
        }
        return writeSession(to: fileURL)
    }

    /// The "Save as" panel, as the menu shows it — title, suggested name, folder creation. Static
    /// so the one other door that has to ask for a path, the save a CLOSING tab owes when it never
    /// had a file (`Workspace.settleUnsavedChanges`, which may be saving a tab that is not the
    /// active one, hence not `self`'s own name), shows the very same panel rather than a copy of it.
    static func makeSaveAsPanel(projectURL: URL?, projectName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = L("project.saveAs.title")
        panel.nameFieldStringValue = projectURL.map { projectDisplayName(for: $0) }
            ?? (projectName == L("project.untitled") ? L("project.defaultName") : projectName)
        panel.canCreateDirectories = true
        return panel
    }

    /// Where "Save as" writes for what the panel handed back — the naming rule, alone, so the
    /// active tab (`saveAs(to:)`) and a parked one (`Workspace`) cannot name a project two ways.
    static func saveAsFileURL(for chosen: URL) -> URL {
        let parent = chosen.deletingLastPathComponent()
        // What was chosen is a NAME, the panel imposing nothing: a project called "test" gives
        // `test/test.json`, the manifest bearing the project's name and nothing else.
        let base = projectDisplayName(for: chosen)
        let fileName = "\(base).json"
        if isObjekatProjectFolder(parent) {
            return parent.appendingPathComponent(fileName)
        }
        return parent.appendingPathComponent(base, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// A folder is an Objekat project if it holds `waveforms/`, which `writeSession` lays for
    /// every project — so the test catches them all. A bare `*.json` is deliberately NOT a sign:
    /// any folder holding some `package.json` would then pass for a project, and "Save as" would
    /// write into it instead of making the folder.
    private static func isObjekatProjectFolder(_ folder: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: waveformsDir(in: folder).path,
                                              isDirectory: &isDir) && isDir.boolValue
    }

    /// Serialises the current session, as it would be written into a version file
    /// laid in the current project folder. This is what `project.get_state` returns: ONE SINGLE
    /// definition of the format, so the API and the file cannot diverge. With no saved
    /// project there is no reference folder and the paths stay absolute.
    func encodedSession() throws -> Data {
        guard let folder = projectFolder else {
            return try encodedSession(projectFolder: URL(fileURLWithPath: "/"))
        }
        return try encodedSession(projectFolder: folder)
    }

    /// THE session document, for every writer (a save, `project.get_state`, "Save a copy"): only
    /// the items and the definitions differ from one writer to the other (paths rewritten, registry
    /// filtered), and they are the only parameters. Everything else — tempo, grid, snap, viewport,
    /// annotations — is read HERE, once: "Save a copy" used to build its own document and silently
    /// dropped the snap and the viewport (the initialiser's defaults are nil), and a field added
    /// later would have been dropped the same way.
    func projectDocument(items: [SoundObject],
                         consolidateDefinitions defs: [ConsolidateDefinition]) -> ProjectDocument {
        ProjectDocument(items: items,
                        stems: stems,
                        tempo: tempo,
                        timeSigNumerator: timeSigNumerator,
                        timeSigDenominator: timeSigDenominator,
                        gridMode: gridMode,
                        snapEnabled: snapEnabled,
                        consolidateDefinitions: defs.isEmpty ? nil : defs,
                        viewport: currentViewport,
                        markerLanes: markerLanes.isEmpty ? nil : markerLanes,
                        comments: comments.isEmpty ? nil : comments)
    }

    /// Serialises the current session (with refreshed plugin states) into JSON. The paths of the
    /// files that live in the project folder are written RELATIVE to `folder` (the folder
    /// this version file lands in): moving the folder breaks no link.
    /// See `ProjectPaths`.
    func encodedSession(projectFolder folder: URL) throws -> Data {
        let doc = projectDocument(items: portableItems(itemsWithCapturedPluginStates(), projectFolder: folder),
                                  consolidateDefinitions: Array(consolidateDefinitions.values))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(doc)
    }

    /// Writes a version file: guarantees the project folder's tree
    /// (samples/, waveforms/) then writes the JSON. `fileURL` becomes the active version.
    /// Internal (and not private): this is the AppKit-free heart `project.save` /
    /// `project.save_as` plug into, with `saveAs()` keeping the choice of path through a panel.
    @discardableResult
    func writeSession(to fileURL: URL) -> Bool {
        do {
            let folder = fileURL.deletingLastPathComponent()
            try Self.createProjectTree(in: folder)
            try encodedSession(projectFolder: folder).write(to: fileURL, options: .atomic)
            projectURL = fileURL
            projectName = displayName(for: fileURL)
            isDirty = false
            recordRecentProject(fileURL)
            return true
        } catch {
            return false
        }
    }

    /// Guarantees a project folder's tree (itself, `waveforms/`, `samples/`) — the half of
    /// `writeSession` that has nothing to do with the view-model's own state, shared with
    /// `writeDocument`.
    private static func createProjectTree(in folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: waveformsDir(in: folder), withIntermediateDirectories: true)
        try fm.createDirectory(at: samplesDir(in: folder), withIntermediateDirectories: true)
    }

    /// Writes an ALREADY-BUILT document to disk (the project tree, then the JSON) with NO effect
    /// on any view-model's state — the door used to save a PARKED tab (Workspace, tabs INC1) that
    /// is not the active project: `writeSession` stays the door for the active one (it also
    /// updates `projectURL`/`projectName`/`isDirty`, none of which make sense for a tab nobody is
    /// looking at). Same tree, same JSON shape (pretty, sorted keys) — one definition either way.
    static func writeDocument(_ doc: ProjectDocument, to fileURL: URL, projectFolder folder: URL) throws {
        try createProjectTree(in: folder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Empties the current project and starts again from a new one.
    func newProject() {
        guard confirmDiscardIfDirty() else { return }
        newProjectDiscardingChanges()
    }

    /// The heart of "new project", WITHOUT a confirmation dialogue — the same split as
    /// `loadProject()` / `loadProject(from:)`. This is what the `project.new` command calls:
    /// a script cannot answer a modal, and the caller has `app.info` to know whether the
    /// project is modified before deciding.
    func newProjectDiscardingChanges() {
        engine?.stop()
        for stem in stems where stem.id != mainStemID {
            let memberIDs = allClips.filter { $0.stemID == stem.id }.map { $0.id.uuidString }
            engine?.disbandStemBus(stem.id.uuidString, memberIDs: memberIDs)
        }
        for item in items { removeFromEngine(item) }
        items = []
        stems = [Stem(id: UUID(), name: "Main", colorIndex: 0, format: .stereo)]
        engine?.setMasterStemKey(mainStemID.uuidString)   // purges the old master rack + a new key
        selectedIDs = []
        undoStack = []
        redoStack = []
        consolidateDefinitions = [:]
        markerLanes = []
        comments = []
        consolidateEditStack.removeAll()
        resetTransientSessionState()
        timeSelection = nil
        loopModeEnabled = false
        loopRegion = nil
        cursorPosition = 0
        caretLane = nil
        timeSelectionOrigin = nil    // the point ⇧ extends from: another project's, hence nobody's
        isRestoringTransport = true
        tempo = 120.0
        timeSigNumerator = 4
        timeSigDenominator = 4
        isRestoringTransport = false
        gridMode = .time
        snapEnabled = true          // a fresh project is on the grid — @see ProjectDocument.snapEnabled
        projectURL = nil
        projectName = L("project.untitled")
        isDirty = false
        projectLoadToken &+= 1   // the canvas rearmed on emptiness (@see projectLoadToken)
        pendingViewRestore = nil
        pendingNewProjectFrame = true
        // Empties the missing-file verdict with the rest: the paths of the project just closed
        // belong to nothing any more, and a stale entry would have `project.missing_files` report
        // broken files in an empty project. Costs nothing here — there are no clips left to ask
        // about. See EditViewModel+MissingFiles.
        rescanMissingFiles()
    }

    /// Opens a version file: you navigate into the project folder and
    /// pick the "<project> V<n>.json" wanted.
    func loadProject() {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.title = L("project.open.title")
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            loadProject(from: url)
        }
    }

    /// The breathing twin of `loadProject()` — the menu's "Open…" entry point, so opening from the
    /// panel shows the same overlay as opening a recent project or through `project.open`.
    func loadProjectAsyncFromPanel() async {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.title = L("project.open.title")
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let url: URL? = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
        guard let url else { return }
        await loadProjectAsync(from: url)
    }

    /// The fully SYNCHRONOUS path: no run loop is breathed on, so this is the only one safe to call
    /// before `app.run()` (HeadlessRunner's `--project`, which has none yet to breathe on) — and
    /// the one every other caller reaches for when it does not need the progress overlay either
    /// (a script's `project.open {"async": false}`, which is also the DEFAULT — the contract stays
    /// unchanged). See `loadProjectAsync(from:)` for the breathing twin the menu and an
    /// `async: true` open use instead.
    /// Reads and decodes a version file, resolving its internal paths (samples/consolidate, the
    /// legacy samples/objects, samples/sources) ABSOLUTE in the project's own folder — the half of
    /// `loadProject(from:)` / `loadProjectAsync(from:)` with no view-model state and no engine
    /// apply, so a caller can decode a candidate file BEFORE deciding anything about it (the
    /// Workspace, tabs INC1, decodes before parking the current tab — a decode failure this way
    /// never touches the tab already open). See `ProjectPaths.resolved`.
    func decodeProjectDocument(at url: URL) throws -> ProjectDocument {
        let data = try Data(contentsOf: url)
        var doc = try JSONDecoder().decode(ProjectDocument.self, from: data)
        doc.items = resolvedItems(doc.items, projectFolder: url.deletingLastPathComponent())
        return doc
    }

    @discardableResult
    func loadProject(from url: URL) -> Bool {
        do {
            let doc = try decodeProjectDocument(at: url)
            applyProjectDocument(doc, displayName: Self.projectDisplayName(for: url))
            projectURL = url
            projectName = displayName(for: url)
            isDirty = false
            recordRecentProject(url)
            return true
        } catch {
            return false
        }
    }

    /// The breathing twin of `loadProject(from:)`: same reading and the same result, but the
    /// document is applied through `applyProjectDocumentAsync`, which yields the run loop between
    /// phases (and, in the plugin phase, between every compile) so `ProjectLoadOverlay` can be
    /// drawn and `project.load_status` answered while it runs. Only safe where the run loop is
    /// confirmed alive — the menu (a window is open) and `project.open {"async": true}` /
    /// the plain awaited path once the command server is serving (both imply `app.run()` has
    /// already been entered). NEVER call this from `HeadlessRunner`'s pre-`app.run()` opening.
    @discardableResult
    func loadProjectAsync(from url: URL) async -> Bool {
        do {
            let doc = try decodeProjectDocument(at: url)
            let ok = await applyProjectDocumentAsync(doc, displayName: Self.projectDisplayName(for: url))
            lastProjectLoad?.path = url.path
            guard ok else { return false }
            projectURL = url
            projectName = displayName(for: url)
            isDirty = false
            recordRecentProject(url)
            return true
        } catch {
            // Clears `loadState` even though `applyProjectDocumentAsync` was never reached: the
            // `async: true` API path sets a PLACEHOLDER `loadState` synchronously before this
            // function is even scheduled (@see project.open), and a decode failure here must not
            // leave `isLoadingProject` stuck true forever.
            loadState = nil
            lastProjectLoad = ProjectLoadOutcome(path: url.path, success: false,
                                                 errorMessage: String(describing: error), durationMs: 0)
            return false
        }
    }

    /// TRANSIENT session state to purge when changing project (a new project or a
    /// load): the clipboard (pasting across projects would insert objects with dangling stemID /
    /// auxID / consolidateID), the note selection, the bakes under way (their
    /// completions find the object gone and give up cleanly) and the UI states of the
    /// piano rolls (keys = UUIDs of the old project).
    /// `preservingClipboard`: tabs INC2 — a tab SWITCH reloads this same VM's state underneath the
    /// hand exactly like a load does, but it is not a change of project as far as the LOCAL
    /// clipboard goes: `Workspace.restoreParkedProject` passes `true` here so that switching away
    /// and back still finds what was copied. `CrossProjectImport` is what makes this safe now —
    /// a paste into a DIFFERENT tab never trusts these ids as they stand, it remaps them
    /// (@see EditViewModel+CrossProjectPaste.swift). Every other caller (a genuine New/Open)
    /// leaves this false, and the danger the original comment names is exactly why: pasting the
    /// OLD document's ids into a truly different one, with no remap, is the corruption this reset
    /// exists to prevent.
    func resetTransientSessionState(preservingClipboard: Bool = false) {
        selectedAnnotation = nil
        clearAutomationPointSelection()
        if !preservingClipboard {
            clipboard = nil
            midiNotesClipboard = nil
        }
        selectedMidiNoteIDs = []
        focusedMidiClipID = nil
        bakingIDs = []
        // Solo (session state, not persisted): starts again from nothing on a new project / an opening,
        // otherwise orphan IDs would remain. No engine apply here (the graph is rebuilt).
        soloedIDs = []
        soloedStemIDs = []
        tempSoloRoots = nil
        heldSoloActive = false
        soloKeyHeld = false
        soloAudibleObjectIDs = []
        audibility = AudibilitySnapshot()   // otherwise solo roots from the previous project
                                            // would survive in the silence rule
        resetConsolidateEditSession()   // stops the listening on the params + the re-mirroring pending
        pianoRollBasePitchByClip = [:]
        pianoRollCropByClip = [:]
        pianoRollCropOffsetByClip = [:]
    }

    /// Returns true if it is safe to carry on straight away (a clean project, or
    /// the user accepts losing the changes). On "Save", it only carries on
    /// if the file is known (a synchronous write); otherwise it opens the panel and
    /// gives up the current operation (return false) to avoid any data loss.
    /// The quit entry point (Cmd+Q / closing the app): the same guard as New/Open.
    /// true = safe to quit (a clean project, saved, or the loss accepted).
    func confirmSaveBeforeQuit() -> Bool { confirmDiscardIfDirty(titleKey: "dialog.dirty.title.quit") }

    /// Internal (not private) since tabs INC1: the Workspace's `replaceActive(with:)` (Cmd+O) goes
    /// through the SAME guard as New/Open, one definition either way.
    func confirmDiscardIfDirty(titleKey: String = "dialog.dirty.title.continue") -> Bool {
        guard isDirty else { return true }
        switch askDirtyDecision(titleKey: titleKey) {
        case .save:
            // A known file → a synchronous write, and we carry on. Otherwise the panel has to be
            // gone through, and it is asynchronous: we give up the current operation (false) rather
            // than risk seeing it run before the user has chosen where to write.
            // And a write that FAILS is not a save: `save()` swallows the error, so carrying on
            // behind it would throw away exactly the changes the user just asked to keep.
            if let url = projectURL {
                guard writeSession(to: url) else {
                    notify(L("tabs.saveTab.failed.title"), L("dialog.dirty.saveFailed.info", projectName))
                    return false
                }
                return true
            }
            saveAs()
            return false
        case .discard:
            return true
        case .cancel:
            return false
        }
    }

    /// Returns a copy of an object (recursive over the children) where every plugin has
    /// its `stateXML` refreshed from the engine (params + binary state), WITHOUT
    /// changing the UUIDs. Used to freeze the state before a copy/cut (the clipboard)
    /// or when saving. Does not mutate the model.
    func withCapturedPluginStates(_ obj: SoundObject) -> SoundObject {
        var o = obj
        if !obj.plugins.isEmpty {
            o.plugins = capturingPluginStates(obj.plugins)
        }
        if !obj.instruments.isEmpty {
            o.instruments = capturingPluginStates(obj.instruments)
        }
        if case .group(let children, let isExpanded) = obj.kind {
            o.kind = .group(children: children.map { withCapturedPluginStates($0) },
                            isExpanded: isExpanded)
        }
        return o
    }

    /// Refreshes `stateXML` from the engine for every plugin leaf, descending
    /// recursively into the voices of a parallel block (`rack`). A rack block has no
    /// state of its own — only its leaves have.
    private func capturingPluginStates(_ plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.map { plug in
            var p = plug
            if let rack = plug.rack {
                p.rack?.voices = rack.voices.map { capturingPluginStates($0) }
            } else {
                pluginStateCaptureCount += 1
                if let xml = engine?.getPluginStateXML(plug.id.uuidString), !xml.isEmpty {
                    p.stateXML = xml
                }
            }
            return p
        }
    }

    /// Returns a copy of `items` where every plugin has its `stateXML` refreshed
    /// from the engine, for a complete persistence. Does not mutate `items`.
    func itemsWithCapturedPluginStates() -> [SoundObject] {
        items.map { withCapturedPluginStates($0) }
    }

    /// The same for the bus FX chains carried by `stems` (INC 2). Does not mutate `stems`.
    func stemsWithCapturedPluginStates() -> [Stem] {
        stems.map { stem in
            var s = stem
            if !stem.plugins.isEmpty { s.plugins = capturingPluginStates(stem.plugins) }
            return s
        }
    }

    /// The synchronous façade this always was — UNCHANGED in contract for every existing caller.
    /// The body now lives in `EditViewModel+ProjectLoad.swift` (`runProjectLoad`), split into
    /// phases with a fixed progress weighting, the FX/instrument compiles DEFERRED to their own
    /// phase, and the engine's graph reallocation inhibited for the whole of it. `displayName` is
    /// what `ProjectLoadOverlay` and `project.load_status` show WHILE it runs — `loadProject(from:)`
    /// knows it before the document is even decoded, `applyProjectDocument`/`project.get_state`'s
    /// other, name-less callers fall back on the current `projectName`.
    func applyProjectDocument(_ doc: ProjectDocument, displayName: String? = nil) {
        runProjectLoad(doc, displayName: displayName)
    }

    /// The breathing twin: same phases, same result on the model, but yields the run loop between
    /// them (and between every plugin compile) so the overlay can be drawn and `project.load_status`
    /// answered while it runs. See `EditViewModel+ProjectLoad.swift`.
    @discardableResult
    func applyProjectDocumentAsync(_ doc: ProjectDocument, displayName: String? = nil,
                                   cancellable: Bool = true,
                                   preservingClipboard: Bool = false) async -> Bool {
        await runProjectLoadAsync(doc, displayName: displayName, cancellable: cancellable,
                                  preservingClipboard: preservingClipboard)
    }

    /// Shows a confirmation listing the plugins the engine could not load during
    /// the opening (the user has not installed them). They have already been removed from the objects
    /// concerned by `compileRack` — the rest of the project opens normally.
    func reportMissingPlugins(_ names: Set<String>) {
        let sorted = names.sorted()
        // Deferred: lets the project's window refresh before the modal (loading is often
        // triggered from the completion of an NSOpenPanel).
        DispatchQueue.main.async {
            self.notify(L("plugins.missing.title"),
                        L("plugins.missing.onOpen.info", self.projectName,
                          sorted.map { "• \($0)" }.joined(separator: "\n")))
        }
    }
}

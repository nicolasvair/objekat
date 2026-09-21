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

    // MARK: - Saving / loading a project

    /// The current project folder: the parent of the active version file.
    var projectFolder: URL? { projectURL?.deletingLastPathComponent() }

    /// The project's `waveforms/` folder (nil as long as the project has not been saved).
    var waveformsFolder: URL? { projectFolder.map { waveformsDir(in: $0) } }

    private func waveformsDir(in folder: URL) -> URL {
        folder.appendingPathComponent("waveforms", isDirectory: true)
    }
    private func samplesDir(in folder: URL) -> URL {
        folder.appendingPathComponent("samples", isDirectory: true)
    }

    /// The display name of a version file: strips ".objekat.json".
    private func displayName(for fileURL: URL) -> String {
        Self.projectDisplayName(for: fileURL)
    }

    /// The NAME of a project as it is shown and typed: with no ".objekat.json" and no
    /// ".objekat" — the extension is an internal matter of the manifest, never something the
    /// user names. Strips only the KNOWN suffixes, and never a path extension of its own
    /// making: "Mix 1.2" is a name, not a file with a ".2" extension.
    /// Shared by the window title, the panel and the "Recent projects" menu, so that one
    /// project has one name everywhere.
    static func projectDisplayName(for url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".objekat.json", ".objekat", ".json"] where name.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            return base.isEmpty ? name : base
        }
        return name
    }

    /// Saves into the active version if there is one, otherwise "Save as".
    func save() {
        if let url = projectURL {
            writeSession(to: url)
        } else {
            saveAs()
        }
    }

    /// Save as: the user chooses the NAME + the location of the project.
    /// A project is a FOLDER, so what is typed here is a plain name — "My Project", never
    /// "My Project.objekat": no content type is imposed on the panel, and the ".objekat.json"
    /// of the manifest is laid by `saveAs(to:)`, which is the only one to know about it.
    /// If the destination is already an Objekat project folder → only the JSON is written there
    /// (several versions can live side by side, sharing samples/ and waveforms/).
    /// Otherwise → a project folder named after what was typed is created and written into.
    func saveAs() {
        let panel = NSSavePanel()
        panel.title = L("project.saveAs.title")
        panel.nameFieldStringValue = projectURL.map { Self.projectDisplayName(for: $0) }
            ?? (projectName == L("project.untitled") ? L("project.defaultName") : projectName)
        panel.canCreateDirectories = true
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
    func saveAs(to chosen: URL) {
        let parent = chosen.deletingLastPathComponent()
        // What was chosen is a NAME (the panel no longer imposes anything), but a path carrying
        // the old ".objekat.json" still says the same thing: both come back to the same base.
        let base = Self.projectDisplayName(for: chosen)
        let fileName = "\(base).objekat.json"
        let fileURL: URL
        if isObjekatProjectFolder(parent) {
            fileURL = parent.appendingPathComponent(fileName)
        } else {
            fileURL = parent.appendingPathComponent(base, isDirectory: true)
                .appendingPathComponent(fileName)
        }
        writeSession(to: fileURL)
    }

    /// A folder is an Objekat project if it holds `waveforms/` or a `*.objekat.json`.
    private func isObjekatProjectFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: waveformsDir(in: folder).path, isDirectory: &isDir), isDir.boolValue {
            return true
        }
        let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.contains { $0.lastPathComponent.hasSuffix(".objekat.json") }
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

    /// Serialises the current session (with refreshed plugin states) into JSON. The paths of the
    /// files that live in the project folder are written RELATIVE to `folder` (the folder
    /// this version file lands in): moving the folder breaks no link.
    /// See `ProjectPaths`.
    func encodedSession(projectFolder folder: URL) throws -> Data {
        let doc = ProjectDocument(items: portableItems(itemsWithCapturedPluginStates(), projectFolder: folder),
                                  stems: stems,
                                  tempo: tempo,
                                  timeSigNumerator: timeSigNumerator,
                                  timeSigDenominator: timeSigDenominator,
                                  gridMode: gridMode,
                                  snapEnabled: snapEnabled,
                                  objectDefinitions: objectDefinitions.isEmpty ? nil : Array(objectDefinitions.values),
                                  viewport: currentViewport,
                                  markerLanes: markerLanes.isEmpty ? nil : markerLanes,
                                  comments: comments.isEmpty ? nil : comments)
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
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.createDirectory(at: waveformsDir(in: folder), withIntermediateDirectories: true)
            try fm.createDirectory(at: samplesDir(in: folder), withIntermediateDirectories: true)
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
        objectDefinitions = [:]
        markerLanes = []
        comments = []
        objectEditStack.removeAll()
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
        // Empties the missing-file verdict with the rest: the paths of the project just closed
        // belong to nothing any more, and a stale entry would have `project.missing_files` report
        // broken files in an empty project. Costs nothing here — there are no clips left to ask
        // about. See EditViewModel+MissingFiles.
        rescanMissingFiles()
    }

    /// Opens a version file: you navigate into the project folder and
    /// pick the "<project> V<n>.objekat.json" wanted.
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

    @discardableResult
    func loadProject(from url: URL) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            var doc = try JSONDecoder().decode(ProjectDocument.self, from: data)
            // Internal paths (samples/objects, samples/sources) made absolute IN this
            // project folder: that is what makes the folder movable, and what catches up
            // projects predating portability. See `ProjectPaths.resolved`.
            doc.items = resolvedItems(doc.items, projectFolder: url.deletingLastPathComponent())
            applyProjectDocument(doc)
            projectURL = url
            projectName = displayName(for: url)
            isDirty = false
            recordRecentProject(url)
            return true
        } catch {
            return false
        }
    }

    /// TRANSIENT session state to purge when changing project (a new project or a
    /// load): the clipboard (pasting across projects would insert objects with dangling stemID /
    /// auxID / definitionID), the note selection, the bakes under way (their
    /// completions find the object gone and give up cleanly) and the UI states of the
    /// piano rolls (keys = UUIDs of the old project).
    private func resetTransientSessionState() {
        selectedAnnotation = nil
        clipboard = nil
        midiNotesClipboard = nil
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
        resetObjectEditSession()   // stops the listening on the params + the re-mirroring pending
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

    private func confirmDiscardIfDirty(titleKey: String = "dialog.dirty.title.continue") -> Bool {
        guard isDirty else { return true }
        switch askDirtyDecision(titleKey: titleKey) {
        case .save:
            // A known file → a synchronous write, and we carry on. Otherwise the panel has to be
            // gone through, and it is asynchronous: we give up the current operation (false) rather
            // than risk seeing it run before the user has chosen where to write.
            if projectURL != nil { save(); return true }
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

    func applyProjectDocument(_ doc: ProjectDocument) {
        // Arms the collection of the plugins that cannot be found: every FX chain recompilation
        // triggered below (clips, groups, stem buses) will drop into it the plugins the
        // engine does not resolve. A single summary is shown at the end of loading.
        missingPluginCapture = []
        engine?.stop()
        for stem in stems where stem.id != mainStemID {
            let memberIDs = allClips.filter { $0.stemID == stem.id }.map { $0.id.uuidString }
            engine?.disbandStemBus(stem.id.uuidString, memberIDs: memberIDs)
        }
        // Clean the engine through the top-level items (handles clips AND groups/ContainerClips).
        for item in items { removeFromEngine(item) }
        items = []
        stems = []
        selectedIDs = []
        undoStack = []
        redoStack = []
        objectDefinitions = Dictionary(uniqueKeysWithValues: (doc.objectDefinitions ?? []).map { ($0.id, $0) })
        // The annotations: restored as they are, with nothing to reconcile — no engine object
        // stands behind a marker or a comment.
        markerLanes = doc.markerLanes ?? []
        comments = doc.comments ?? []
        objectEditStack.removeAll()
        resetTransientSessionState()

        // Tempo / time signature / grid mode: RESTORED data → pushed to the engine with no remap
        // and without marking the project modified (the document's positions are the authority).
        isRestoringTransport = true
        if let t = doc.tempo { tempo = t }
        if let n = doc.timeSigNumerator { timeSigNumerator = n }
        if let d = doc.timeSigDenominator { timeSigDenominator = d }
        isRestoringTransport = false
        if let g = doc.gridMode { gridMode = g }
        // The snap as the project was left. An older file has no key and opens WITH the snap, which
        // is also where the app starts: the default is 'on', what is restored is a deliberate 'off'.
        snapEnabled = doc.snapEnabled ?? true

        // The view (H/V zoom + visible area): applied as saved. The scroll cannot
        // be set here (it belongs to the ScrollView) → dropped into `pendingViewRestore`,
        // which the TimelineView consumes once the content is in place.
        if let vp = doc.viewport {
            pixelsPerSecond = max(1, vp.pixelsPerSecond)
            blockHeight     = max(16, vp.blockHeight)
            pendingViewRestore = vp
        }

        if let docStems = doc.stems, !docStems.isEmpty {
            stems = docStems
        } else {
            stems = [Stem(id: UUID(), name: "Main", colorIndex: 0, format: .stereo)]
        }
        // Declares the Main's new key to the engine (routes the master FX chain + purges the old one).
        engine?.setMasterStemKey(mainStemID.uuidString)

        items = doc.items

        // Rebuild the engine from the top-level items: syncAdd recursively handles
        // the .clips (a direct AudioTrack) and the .groups (ContainerClip + children).
        for item in items {
            syncAdd(item)
            switch item.kind {
            case .clip, .midiClip:
                engine?.updateFade(in: item.fadeIn, fadeOut: item.fadeOut,
                                   forID: item.id.uuidString)
            default: break
            }
            // The fades of the clips that are children of a group are applied in syncAddGroup.
        }
        for stem in stems.dropFirst() {
            engine?.createStemBus(stem.id.uuidString)
            let clipIDs = allClips.filter { $0.stemID == stem.id }.map { $0.id.uuidString }
            let groupIDs = items.compactMap { item -> String? in
                guard case .group = item.kind, item.stemID == stem.id else { return nil }
                return item.id.uuidString
            }
            let memberIDs = clipIDs + groupIDs
            if !memberIDs.isEmpty {
                engine?.assignObjects(memberIDs, toStemID: stem.id.uuidString)
            }
        }
        resyncAllSends()   // every aux now exists → wire the saved sends
        syncStemGains()    // reapplies the remembered bus levels (mixer)
        syncStemPlugins()  // reapplies the remembered bus FX chains (stems + master)
        syncStemRouting()  // reapplies the remembered routing to the Main (detached buses)
        refreshAudibility()  // remembered bus mutes → a composed silence on every object

        // The content is in place: the timeline can rearm the length of its canvas (@see
        // projectLoadToken). To be done AFTER `items`, otherwise it would rearm on the old content.
        projectLoadToken &+= 1

        // The files the clips name are asked about ONCE, here: `items` is in place and the engine
        // has been fed, so the answer is about the project that is actually open. It has to happen
        // AFTER `resolvedItems` has made the internal paths absolute (@see loadProject(from:)),
        // otherwise every sample living in the project folder would read as gone. From now on
        // nothing touches the disk again until a relink or a volume moves — the drawing side reads
        // `missingPaths` and nothing else. See EditViewModel+MissingFiles.
        rescanMissingFiles()
        // And the watch on the volumes, which is what makes `.volumeOffline` mend itself when the
        // drive comes back. Idempotent: every later opening finds it already laid.
        armMissingFileWatch()

        // End of loading: if plugins were missing, warn the user (once only).
        let missing = missingPluginCapture ?? []
        missingPluginCapture = nil
        if !missing.isEmpty { reportMissingPlugins(missing) }
    }

    /// Shows a confirmation listing the plugins the engine could not load during
    /// the opening (the user has not installed them). They have already been removed from the objects
    /// concerned by `compileRack` — the rest of the project opens normally.
    private func reportMissingPlugins(_ names: Set<String>) {
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

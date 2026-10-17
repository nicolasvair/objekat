import Foundation

// MARK: - Disk usage of the project folder: how much is there, how much does nothing read any more
//
// The disk half of `ProjectFileUsage` (the pure half, which decides what "used" means). This file
// does three things and nothing else:
//   1. on the MAIN thread, reduces what is in memory to plain values (`DiskUsageInput`): the
//      session's own tree, and the roots that something else still holds (open or parked tabs,
//      the clipboards, a consolidated object being edited);
//   2. off the main thread, lists the folder, reads the OTHER versions of the folder and the
//      sidecars, and classifies (`DiskUsageScanner`, which touches no view-model);
//   3. publishes the answer (`diskUsage`), dropping the answer of a scan a newer one overtook.
//
// The scan is never continuous: it runs after a load (a tab switch is a load), after a save, when
// the popover opens, and on demand through the API. A project that was never saved has no folder,
// hence no figures at all.
//
// WHAT COUNTS AS "READ". The current version is read from MEMORY (the truth: it is what the next
// save will write) — and, while it is modified, from its SAVED file as well, which is protected:
// closing without saving must not leave the file on disk pointing at something already in the
// Trash. Every OTHER version of the folder is read from its file. A file read by another version
// is USED ELSEWHERE: the `folder` scope keeps it, the `session` scope offers it (unticked, with the
// versions that read it named). What the clipboards and the other tabs hold is PROTECTED.

// MARK: - Values handed to the scan (nothing here touches the model or the disk)

/// What one holder reads: a tree of objects and the registry its instances name. `folder` is where
/// its consolidated waves (and their sidecars) are looked up; `extraDirs` the per-definition
/// fallbacks (`consolidateFallbackDirs`).
nonisolated struct DiskUsageRoots: Sendable {
    var name: String
    var folder: URL?
    var items: [ProjectFileUsage.Ref]
    var defs: [UUID: ProjectFileUsage.DefInfo]
    var extraDirs: [UUID: [URL]]

    init(name: String, folder: URL?, items: [ProjectFileUsage.Ref],
         defs: [UUID: ProjectFileUsage.DefInfo], extraDirs: [UUID: [URL]] = [:]) {
        self.name = name
        self.folder = folder
        self.items = items
        self.defs = defs
        self.extraDirs = extraDirs
    }
}

nonisolated struct DiskUsageInput: Sendable {
    var folder: URL
    /// The manifest of the version in front: never read as "another version".
    var currentVersion: URL?
    /// True while the version in front has unsaved changes: its saved file is then protected too.
    var protectSavedCurrent: Bool
    var session: DiskUsageRoots
    /// Held by something else that is open: protected whatever the scope.
    var protectedRoots: [DiskUsageRoots]
}

nonisolated struct DiskUsageResult: Sendable, Equatable {
    var folder: URL
    var report: ProjectFileUsage.Report
    /// Everything the folder weighs, files only (the manifests, the media, the caches).
    var totalBytes: Int64
    /// Versions of the folder that look like sessions and could not be decoded. Their files are
    /// NOT protected, which is why the folder scope refuses to answer while there are any (the
    /// session scope answers, and just cannot say whether they read a file).
    var unreadableVersions: [String]
    /// The other versions that were read.
    var versionNames: [String]
    var computedAt: Date

    /// The candidates the user may tick in `scope`, or nil when the scope cannot be answered
    /// (@see `ProjectFileUsage.Report.cleanable`).
    func cleanable(in scope: DiskCleanScope) -> [ProjectFileUsage.Candidate]? {
        report.cleanable(in: scope, unreadableVersions: unreadableVersions)
    }
}

// MARK: - The scan (off the main thread)

nonisolated enum DiskUsageScanner {

    static func scan(_ input: DiskUsageInput) -> DiskUsageResult {
        let folder = input.folder
        let listing = listFolder(folder)
        let universe = ProjectFileUsage.universe(listing: listing)
        let total = listing.reduce(Int64(0)) { $0 + $1.size }

        let session = usage(of: input.session, in: folder)

        var protected = ProjectFileUsage.Usage()
        for root in input.protectedRoots { protected.formUnion(usage(of: root, in: folder)) }

        var others: [ProjectFileUsage.OtherVersion] = []
        var unreadable: [String] = []
        var versionNames: [String] = []
        for url in versionFiles(in: folder) {
            let isCurrent = input.currentVersion.map { sameFile($0, url) } ?? false
            if isCurrent && !input.protectSavedCurrent { continue }
            guard let data = try? Data(contentsOf: url) else { unreadable.append(url.lastPathComponent); continue }
            switch ProjectFileUsage.verdict(of: data) {
            case .notASession: continue            // some other tool's JSON
            case .invalid: unreadable.append(url.lastPathComponent); continue
            case .session: break
            }
            guard let refs = try? ProjectFileUsage.decodeSession(data) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            let roots = DiskUsageRoots(name: url.lastPathComponent, folder: folder, items: refs.items,
                                       defs: Dictionary(uniqueKeysWithValues: refs.defs.map { ($0.id, $0) }))
            let u = usage(of: roots, in: folder)
            if isCurrent {
                protected.formUnion(u)        // the saved copy of the version in front
            } else {
                others.append(.init(name: url.lastPathComponent, usage: u))
                versionNames.append(url.lastPathComponent)
            }
        }

        let report = ProjectFileUsage.classify(universe: universe, session: session,
                                               protected: protected, others: others)
        return DiskUsageResult(folder: folder, report: report, totalBytes: total,
                               unreadableVersions: unreadable.sorted(), versionNames: versionNames.sorted(),
                               computedAt: Date())
    }

    /// What `roots` read, in the terms of `folder`.
    static func usage(of roots: DiskUsageRoots, in folder: URL) -> ProjectFileUsage.Usage {
        let closure = ProjectFileUsage.closure(items: roots.items, defs: roots.defs,
                                               readSidecar: sidecarReader(roots))
        return ProjectFileUsage.usage(of: closure, defs: roots.defs, folder: folder)
    }

    /// Reads a definition's sidecar from wherever one is found: the root's own `samples/consolidate`,
    /// the legacy `samples/objects`, then the per-definition fallbacks. More tolerant than the app
    /// (which reads where the WAVE is): a sidecar found somewhere else only makes the closure
    /// larger, never smaller.
    static func sidecarReader(_ roots: DiskUsageRoots) -> (ProjectFileUsage.DefInfo) -> ProjectFileUsage.Ref? {
        { def in
            guard let base = roots.folder else { return nil }
            let name = ProjectFileUsage.sidecarName(forWave: def.wave)
            for dir in ConsolidateFolders.waveCandidates(projectFolder: base, extraDirs: roots.extraDirs[def.id] ?? []) {
                if let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                   let ref = try? ProjectFileUsage.decodeSidecar(data) { return ref }
            }
            return nil
        }
    }

    /// Every regular file under `folder`, relative to it. Symbolic links are skipped, so one can
    /// never be offered for deletion.
    static func listFolder(_ folder: URL) -> [ProjectFileUsage.Listed] {
        // `realpath`, not `resolvingSymlinksInPath`: the latter turns `/private/tmp/x` into `/tmp/x`
        // while the enumerator reports `/private/tmp/x/…`, and no file would match the prefix.
        let root = URL(fileURLWithPath: realPath(folder.path))
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var out: [ProjectFileUsage.Listed] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            let path = url.path
            guard path.hasPrefix(prefix) else { continue }
            out.append(.init(rel: String(path.dropFirst(prefix.count)), size: Int64(v.fileSize ?? 0)))
        }
        return out
    }

    /// The manifests at the top of the folder (`*.objekat` and the legacy `*.json`).
    static func versionFiles(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { SessionFile.hasSessionExtension($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The canonical path of `path` (every symbolic link resolved, `/private` kept).
    static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buffer) != nil ? String(cString: buffer) : path
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }
}

// MARK: - The view-model's side (main thread)

extension EditViewModel {

    /// What forbids reading — and above all cleaning — the folder right now (an i18n key), nil if
    /// nothing does. The same families as `tabSwitchBlocker`'s render/edit reasons, for the same
    /// cause: a bake is about to write a file the registry does not name yet, and a consolidated
    /// object being edited has its content in `items` in place of the wave it will come back to.
    var diskUsageBusyKey: String? {
        if isLoadingProject { return "diskUsage.busy.loading" }
        if !bakingIDs.isEmpty || !recomputingConsolidateIDs.isEmpty || isCascadingRebake {
            return "diskUsage.busy.render"
        }
        if isEditingConsolidate || !consolidateEditStack.isEmpty { return "diskUsage.busy.consolidateEdit" }
        return nil
    }

    /// The session's own roots: the tree and the registry in memory.
    func diskUsageSessionRoots() -> DiskUsageRoots {
        var extra: [UUID: [URL]] = [:]
        for id in consolidateDefinitions.keys {
            let dirs = consolidateFallbackDirs(forConsolidate: id)
            if !dirs.isEmpty { extra[id] = dirs }
        }
        return DiskUsageRoots(name: projectName, folder: projectFolder,
                              items: items.map(\.fileUsageRef),
                              defs: consolidateDefinitions.mapValues {
                                  ProjectFileUsage.DefInfo(id: $0.id, wave: $0.wave)
                              },
                              extraDirs: extra)
    }

    /// What this tab holds besides its tree: the local clipboard and the consolidated objects being
    /// edited (their instances are materialised in `items`, but the edit can still be cancelled).
    func diskUsageLocalProtectedRoots() -> DiskUsageRoots {
        var refs: [ProjectFileUsage.Ref] = []
        if let clipboard { refs += clipboard.clips.map(\.fileUsageRef) }
        for session in consolidateEditStack {
            refs.append(ProjectFileUsage.Ref(consolidateID: session.defID))
            if let o = session.originalPlacement { refs.append(o.fileUsageRef) }
            refs += session.mirrorSnapshots.values.map(\.fileUsageRef)
        }
        return DiskUsageRoots(name: "clipboard", folder: projectFolder, items: refs,
                              defs: consolidateDefinitions.mapValues {
                                  ProjectFileUsage.DefInfo(id: $0.id, wave: $0.wave)
                              })
    }

    func makeDiskUsageInput() -> DiskUsageInput? {
        guard let folder = projectFolder, let url = projectURL else { return nil }
        return DiskUsageInput(folder: folder, currentVersion: url, protectSavedCurrent: isDirty,
                              session: diskUsageSessionRoots(),
                              protectedRoots: [diskUsageLocalProtectedRoots()] + (diskUsageExtraRootsHook?() ?? []))
    }

    /// Recomputes the figures in the background. A no-op while something forbids it (the previous
    /// figures stay, flagged by `diskUsageBlockedKey`), and clears them for a project with no
    /// folder yet. `completion` is called on the main thread once the result is in (nil when the
    /// scan did not run).
    func refreshDiskUsage(completion: ((DiskUsageResult?) -> Void)? = nil) {
        diskUsageGeneration &+= 1
        let generation = diskUsageGeneration
        guard projectFolder != nil, projectURL != nil else {
            diskUsage = nil
            isComputingDiskUsage = false
            diskUsageBlockedKey = nil
            completion?(nil)
            return
        }
        if let busy = diskUsageBusyKey {
            diskUsageBlockedKey = busy
            isComputingDiskUsage = false
            completion?(nil)
            return
        }
        guard let input = makeDiskUsageInput() else { completion?(nil); return }
        // Figures of ANOTHER project's folder (a tab switch) must not linger while this one computes.
        if let shown = diskUsage, !DiskUsageScanner.sameFile(shown.folder, input.folder) { diskUsage = nil }
        diskUsageBlockedKey = nil
        isComputingDiskUsage = true
        Task.detached(priority: .utility) { [self] in
            let result = DiskUsageScanner.scan(input)
            await MainActor.run {
                guard self.diskUsageGeneration == generation else { completion?(nil); return }
                self.diskUsage = result
                self.isComputingDiskUsage = false
                completion?(result)
            }
        }
    }

    /// Same, awaitable — the API and the cleanup (which recomputes right before trashing).
    func computeDiskUsage() async -> DiskUsageResult? {
        await withCheckedContinuation { continuation in
            refreshDiskUsage { continuation.resume(returning: $0) }
        }
    }
}

// MARK: - The model as `ProjectFileUsage` sees it

extension SoundObject {
    /// This object reduced to what decides which FILES it reads (@see `ProjectFileUsage.Ref`):
    /// an instance of a consolidated object names its definition (and the wave it plays), a clip
    /// its path, a group its children. An aux and a MIDI clip read no file.
    var fileUsageRef: ProjectFileUsage.Ref {
        var path: String?
        var children: [ProjectFileUsage.Ref] = []
        switch kind {
        case .clip(let fp, _, _, _, _): path = fp
        case .group(let kids, _): children = kids.map(\.fileUsageRef)
        case .aux, .midiClip: break
        }
        return ProjectFileUsage.Ref(consolidateID: consolidateID, filePath: path, children: children)
    }
}

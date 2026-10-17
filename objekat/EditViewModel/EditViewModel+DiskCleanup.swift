import Foundation

// MARK: - Cleaning the project folder: unused files go to the TRASH, and come back if needed
//
// Three rules the whole file answers to:
//   • NEVER `removeItem`. Everything goes through `FileManager.trashItem`, and the Trash location
//     it answers (`resultingItemURL`) is kept for the session.
//   • A unit travels together: a wave, its sidecar and its `.wfc` cache are trashed as one, and
//     fetched back as one (`ProjectFileUsage.Candidate.files`).
//   • The undo history is NOT protected (decision of the user, "option B"). Instead, any undo, redo
//     or paste that puts a cleaned file back in play first fetches it back from the Trash to its
//     original place, silently, BEFORE the engine is asked to load it. If the Trash was emptied in
//     the meantime nothing is invented: the file is simply missing, and `MissingFiles` says so.

/// One unit that was sent to the Trash.
struct TrashedFileUnit {
    /// The project folder the files belonged to.
    let projectFolder: URL
    /// The folder-relative path of the unit's primary file (also its key).
    let primary: String
    /// Every file of the unit that is in the Trash: where it was, where it is.
    var files: [TrashedFile]
}

struct TrashedFile {
    let rel: String
    let trash: URL
}

/// Why a clean-up did not run at all.
enum DiskCleanRefusal: Equatable {
    /// The project was never saved: it has no folder.
    case unsaved
    /// A load, a bake or a consolidate edit is under way (an i18n key names which).
    case busy(String)
    /// `Sessions du dossier` needs every other version to be readable.
    case unreadableVersions([String])
    case scanFailed

    var apiCode: String {
        switch self {
        case .unsaved: return "unsaved"
        case .busy: return "busy"
        case .unreadableVersions: return "unreadable_versions"
        case .scanFailed: return "scan_failed"
        }
    }
}

struct DiskCleanOutcome {
    var dryRun: Bool
    var scope: DiskCleanScope
    var refusal: DiskCleanRefusal?
    /// What was (or, in a dry run, would be) sent to the Trash.
    var units: [ProjectFileUsage.Candidate] = []
    /// Asked for, but not on the list of what may be cleaned, with the bucket it is in
    /// (`used`, `protected`, `held`, or `unknown`).
    var rejected: [(id: String, reason: String)] = []
    var failed: [(id: String, message: String)] = []

    var bytes: Int64 { units.reduce(0) { $0 + $1.size } }
}

extension EditViewModel {

    // MARK: - Trashing

    /// Sends the unused files of the project folder to the Trash.
    ///
    /// Everything is recomputed RIGHT BEFORE (a figure on screen can be minutes old), nothing that
    /// is not on the fresh list can be trashed whatever `selection` says, and a dry run (the API's
    /// default) goes through exactly the same checks and moves nothing.
    ///
    /// - Parameter selection: the `id`s (primary file, folder-relative) to clean; nil = all.
    @discardableResult
    func cleanUnusedFiles(selection: Set<String>?, scope: DiskCleanScope, dryRun: Bool) async -> DiskCleanOutcome {
        var outcome = DiskCleanOutcome(dryRun: dryRun, scope: scope)
        guard let folder = projectFolder, projectURL != nil else { outcome.refusal = .unsaved; return outcome }
        if let busy = diskUsageBusyKey { outcome.refusal = .busy(busy); return outcome }
        guard let result = await computeDiskUsage() else {
            outcome.refusal = diskUsageBusyKey.map { .busy($0) } ?? .scanFailed
            return outcome
        }
        // Whatever happened during the scan.
        if let busy = diskUsageBusyKey { outcome.refusal = .busy(busy); return outcome }
        guard let cleanable = result.cleanable(in: scope) else {
            outcome.refusal = .unreadableVersions(result.unreadableVersions)
            return outcome
        }
        let byID = Dictionary(uniqueKeysWithValues: cleanable.map { ($0.id, $0) })
        if let selection {
            for id in selection.sorted() where byID[id] == nil {
                outcome.rejected.append((id, Self.bucket(of: id, in: result.report)))
            }
            outcome.units = cleanable.filter { selection.contains($0.id) }
        } else {
            outcome.units = cleanable
        }
        guard !dryRun else { return outcome }

        let fm = FileManager.default
        var done: [ProjectFileUsage.Candidate] = []
        for unit in outcome.units {
            var moved: [TrashedFile] = []
            var failure: String?
            for rel in unit.files {
                let url = folder.appendingPathComponent(rel)
                guard fm.fileExists(atPath: url.path) else { continue }
                var resulting: NSURL?
                do {
                    try fm.trashItem(at: url, resultingItemURL: &resulting)
                    if let trash = resulting as URL? { moved.append(TrashedFile(rel: rel, trash: trash)) }
                } catch {
                    failure = error.localizedDescription
                    break
                }
            }
            if !moved.isEmpty {
                trashedFileUnits[unit.id] = TrashedFileUnit(projectFolder: folder, primary: unit.id, files: moved)
            }
            if let failure { outcome.failed.append((unit.id, failure)) } else { done.append(unit) }
        }
        outcome.units = done
        rescanMissingFiles()
        refreshDiskUsage()
        return outcome
    }

    private static func bucket(of id: String, in report: ProjectFileUsage.Report) -> String {
        if report.used.contains(where: { $0.id == id }) { return "used" }
        if report.protected.contains(where: { $0.id == id }) { return "protected" }
        if report.held.contains(where: { $0.id == id }) { return "held" }
        return "unknown"
    }

    // MARK: - Fetching back

    /// Fetches back from the Trash every cleaned unit that `items` (with the registry `defs`, the
    /// current one if nil) reads again. Called with the state an undo / redo is about to restore,
    /// and with what a paste is about to lay down, BEFORE the engine is told anything.
    @discardableResult
    func restoreTrashedFiles(forItems items: [SoundObject],
                             defs: [UUID: ConsolidateDefinition]? = nil) -> Int {
        guard !trashedFileUnits.isEmpty, let folder = projectFolder else { return 0 }
        let candidates = trashedFileUnits.values.filter { DiskUsageScanner.sameFile($0.projectFolder, folder) }
        guard !candidates.isEmpty else { return 0 }

        let registry = (defs ?? consolidateDefinitions).mapValues {
            ProjectFileUsage.DefInfo(id: $0.id, wave: $0.wave)
        }
        var extra: [UUID: [URL]] = [:]
        for id in registry.keys {
            let dirs = consolidateFallbackDirs(forConsolidate: id)
            if !dirs.isEmpty { extra[id] = dirs }
        }
        let onDisk = DiskUsageScanner.sidecarReader(
            DiskUsageRoots(name: "restore", folder: folder, items: [], defs: [:], extraDirs: extra))
        // A sidecar that is itself in the Trash is read from there: a nested definition is only
        // discovered through it.
        let trashedByRel = Dictionary(candidates.flatMap { $0.files }.map { ($0.rel, $0.trash) },
                                      uniquingKeysWith: { a, _ in a })
        let reader: (ProjectFileUsage.DefInfo) -> ProjectFileUsage.Ref? = { def in
            if let ref = onDisk(def) { return ref }
            let name = ProjectFileUsage.sidecarName(forWave: def.wave)
            for dir in [ProjectFileUsage.consolidateRel, ProjectFileUsage.legacyRel] {
                if let trash = trashedByRel["\(dir)/\(name)"],
                   let data = try? Data(contentsOf: trash),
                   let ref = try? ProjectFileUsage.decodeSidecar(data) { return ref }
            }
            return nil
        }
        let closure = ProjectFileUsage.closure(items: items.map(\.fileUsageRef), defs: registry, readSidecar: reader)
        let usage = ProjectFileUsage.usage(of: closure, defs: registry, folder: folder)

        var restored = 0
        var lost = false
        let fm = FileManager.default
        for unit in candidates {
            guard unit.files.contains(where: { !$0.rel.hasPrefix("\(ProjectFileUsage.waveformsRel)/")
                                               && usage.rel.contains($0.rel) }) else { continue }
            var remaining: [TrashedFile] = []
            for file in unit.files {
                let original = folder.appendingPathComponent(file.rel)
                if fm.fileExists(atPath: original.path) { continue }          // already back
                guard fm.fileExists(atPath: file.trash.path) else {           // the Trash was emptied
                    if !file.rel.hasPrefix("\(ProjectFileUsage.waveformsRel)/") { lost = true }
                    continue
                }
                do {
                    try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: file.trash, to: original)
                    restored += 1
                } catch {
                    remaining.append(file)
                    lost = true
                }
            }
            if remaining.isEmpty { trashedFileUnits[unit.primary] = nil }
            else { trashedFileUnits[unit.primary]?.files = remaining }
        }
        if restored > 0 || lost {
            rescanMissingFiles()
            refreshDiskUsage()
        }
        return restored
    }
}

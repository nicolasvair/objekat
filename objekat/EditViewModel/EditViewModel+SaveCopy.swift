import AppKit

// MARK: - Save a copy with audio files (a self-contained capsule)
//
// Creates a SELF-CONTAINED project folder holding the project + ALL the audio files it needs,
// and NOTHING more (the orphan waves piled up in samples/consolidate/ after a re-bake are
// excluded). Used to send a "ready to open" copy to somebody else.
//
// A reminder of the model: the SOURCE files of a normal `.clip` point at an EXTERNAL absolute
// path (Sound library/Finder) — they are not in the project folder. Only consolidated-object
// waves (samples/consolidate/, or the legacy samples/objects/ — cas E1, read but never written
// again) live there, each with a JSON sidecar (`*_objectstate.json`) carrying the editable
// sub-tree. Those sidecars themselves reference other files (sources, nested consolidated
// objects) → they are collected by transitive closure so that the recipient can open AND edit
// everything.

/// What a finished "Save a copy" did — handed to `performSaveCopy`'s completion.
struct SaveCopyReport {
    /// The capsule's manifest (`<folder>/<folder>.json`).
    let projectFile: URL
    /// Files copied (sources + consolidated waves; the regenerable `.wfc` caches are not counted).
    let copiedFiles: Int
    /// What the capsule could not carry (absent source, sidecar or definition) — the copy still
    /// succeeded, those links are left as they were.
    let missing: [String]
    /// Write failures. Non-empty = the capsule is incomplete.
    let errors: [String]
    /// Set when the destination was REFUSED (nothing read, nothing written).
    var destinationProblem: SaveCopyDestinationProblem? = nil
    var succeeded: Bool { errors.isEmpty }
}

/// Why a folder cannot receive a copy of the project: it overlaps a folder the copy READS from.
///
/// The copy writes into the destination with "remove what is there, then copy": on a destination
/// that IS the source (or overlaps it) the removal falls on the very file about to be copied — a
/// consolidated wave deleted, then copied from… nothing. That is how a copy onto the project's
/// own folder erased its consolidated waves. The folder is refused up front, before anything is
/// read or written.
struct SaveCopyDestinationProblem: Equatable {
    enum Overlap: Equatable {
        /// The destination IS a folder the copy reads from.
        case sameFolder
        /// The destination lies INSIDE such a folder (e.g. `<project>/samples/`).
        case insideSource
        /// The destination CONTAINS such a folder (e.g. the project's parent folder, whose
        /// `samples/` would then be the project's own).
        case containsSource
    }
    let overlap: Overlap
    /// The folder the copy reads from that the destination overlaps.
    let source: URL
    /// True when `source` is the project's own folder; false for the folder of an OLDER project
    /// the consolidated waves are still read from (the Q3 fallback, after a Save As).
    let sourceIsProject: Bool

    /// For the API (English, stable wording — the code is what a script branches on).
    var apiMessage: String {
        let what = sourceIsProject ? "the project's own folder"
                                   : "a folder the project still reads consolidated waves from"
        switch overlap {
        case .sameFolder:     return "the copy's folder is \(what): \(source.path)"
        case .insideSource:   return "the copy's folder is inside \(what): \(source.path)"
        case .containsSource: return "the copy's folder contains \(what): \(source.path)"
        }
    }

    /// For the alert (localised).
    var localizedInfo: String {
        guard sourceIsProject else { return L("saveCopy.error.destination.readFolder", source.path) }
        switch overlap {
        case .sameFolder:     return L("saveCopy.error.destination.same", source.path)
        case .insideSource:   return L("saveCopy.error.destination.inside", source.path)
        case .containsSource: return L("saveCopy.error.destination.contains", source.path)
        }
    }
}

/// Folder identity that holds on a case-insensitive volume, through symbolic links and through
/// Unicode normalisation: two URLs name the same folder when the FILE SYSTEM says so (its resource
/// identifier), never because two strings compare equal — `/tmp/P` vs `/private/tmp/p` vs a link
/// to it are one and the same folder on APFS, and a string comparison misses all three.
enum FolderIdentity {

    /// The file-system identity of an EXISTING item (symbolic links resolved), nil if absent.
    static func identifier(_ url: URL) -> NSObject? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return (try? resolved.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
            .fileResourceIdentifier as? NSObject
    }

    /// `url` and each of its ancestors up to `/`, symbolic links resolved on the existing part.
    /// A path that does not exist yet (a copy's new folder) is walked from its deepest existing
    /// ancestor: that is where it WILL be created.
    static func existingChain(_ url: URL) -> [URL] {
        var u = url.standardizedFileURL
        let fm = FileManager.default
        while !fm.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        u = u.resolvingSymlinksInPath()
        var chain = [u]
        while u.path != "/" {
            u = u.deletingLastPathComponent()
            chain.append(u)
        }
        return chain
    }

    /// True if `a` and `b` are the same existing file or folder.
    static func same(_ a: URL, _ b: URL) -> Bool {
        guard let ia = identifier(a), let ib = identifier(b) else { return false }
        return ia.isEqual(ib)
    }
}

extension EditViewModel {

    /// Menu entry point: "Save a copy with audio files…".
    func saveCopyWithAudioFiles() {
        let panel = NSSavePanel()
        panel.title = L("saveCopy.panel.title")
        panel.message = L("saveCopy.panel.message")
        panel.prompt = L("saveCopy.panel.prompt")
        panel.nameFieldLabel = L("saveCopy.panel.nameLabel")
        let base = projectName == L("project.untitled") ? L("project.defaultName") : projectName
        panel.nameFieldStringValue = L("saveCopy.defaultName", base)
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self, response == .OK, let dest = panel.url else { return }
            // `performSaveCopy` refuses an overlapping destination itself (with the alert): the
            // panel happily offers the project's own folder, and "Replace" on it was a data loss.
            self.performSaveCopy(to: dest)
        }
    }

    // MARK: - Where a copy may NOT go

    /// The folders the copy READS from and must therefore never write into: the project's folder,
    /// plus the project folder of every consolidated wave read from elsewhere (the Q3 fallback — a
    /// Save As leaves the waves in the OLD project's folder until the next re-bake).
    func saveCopySourceFolders() -> [URL] {
        var out: [URL] = []
        if let projectFolder { out.append(projectFolder) }
        for (defID, def) in consolidateDefinitions {
            guard let folder = consolidateReadFolder(forWave: def.wave, definition: defID) else { continue }
            // `<project>/samples/<consolidate|objects>` → `<project>`; any other layout → the folder itself.
            let samples = folder.deletingLastPathComponent()
            let root = samples.lastPathComponent == "samples" ? samples.deletingLastPathComponent() : folder
            if !out.contains(where: { FolderIdentity.same($0, root) || $0.standardizedFileURL == root.standardizedFileURL }) {
                out.append(root)
            }
        }
        return out
    }

    /// nil if `dest` may receive a copy; otherwise the first overlap found with a folder the copy
    /// reads from (@see SaveCopyDestinationProblem). Identity is the FILE SYSTEM's, so a different
    /// case, a symbolic link or `/tmp` vs `/private/tmp` are all seen through (@see FolderIdentity).
    func saveCopyDestinationProblem(_ dest: URL) -> SaveCopyDestinationProblem? {
        let destChain = FolderIdentity.existingChain(dest)
        let destExists = FileManager.default.fileExists(
            atPath: dest.standardizedFileURL.resolvingSymlinksInPath().path)
        for (n, source) in saveCopySourceFolders().enumerated() {
            guard let sourceID = FolderIdentity.identifier(source) else { continue }
            let isProject = n == 0 && projectFolder != nil
            // dest == source, or dest (or where it will be created) under source.
            for (i, ancestor) in destChain.enumerated() {
                guard let id = FolderIdentity.identifier(ancestor), id.isEqual(sourceID) else { continue }
                return SaveCopyDestinationProblem(overlap: (i == 0 && destExists) ? .sameFolder : .insideSource,
                                                  source: source, sourceIsProject: isProject)
            }
            // source under dest (only an existing dest can contain anything).
            if destExists, let destID = FolderIdentity.identifier(dest) {
                for ancestor in FolderIdentity.existingChain(source).dropFirst() {
                    if let id = FolderIdentity.identifier(ancestor), id.isEqual(destID) {
                        return SaveCopyDestinationProblem(overlap: .containsSource, source: source,
                                                          sourceIsProject: isProject)
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Carrying it out

    /// Prepares the copy (capturing plugin states + discovery + rewriting paths, on the main
    /// thread), then does the file I/O in the background and reports the result.
    ///
    /// Internal (and not private): this is the AppKit-free heart of "Save a copy", the one external
    /// driving will call directly, skipping the panel but not a single line of the copying
    /// logic (`project.save_copy`).
    ///
    /// `completion` is called on the main thread once EVERY write is over, after the final alert
    /// (which itself goes through the dialogue policy) — it is what lets the API wait for the end
    /// instead of guessing it.
    func performSaveCopy(to destFolder: URL, completion: ((SaveCopyReport) -> Void)? = nil) {
        // The manifest bears the folder's name and nothing more: "My Project copy/My Project copy.json".
        let folderName = EditViewModel.projectDisplayName(for: destFolder)
        let projectFileURL = destFolder.appendingPathComponent("\(folderName).json")

        // A destination overlapping a folder the copy reads from is refused BEFORE anything is
        // read or written: the "remove, then copy" of step 7 would otherwise delete the very
        // files it is about to copy (the consolidated waves of the project's own folder).
        if let problem = saveCopyDestinationProblem(destFolder) {
            notify(L("saveCopy.error.destination.title"), problem.localizedInfo)
            completion?(SaveCopyReport(projectFile: projectFileURL, copiedFiles: 0, missing: [],
                                       errors: [problem.apiMessage], destinationProblem: problem))
            return
        }

        // Destination folders. The copy NORMALISES: every consolidated wave lands in
        // `samples/consolidate/`, wherever it was actually read from (cas E1/E6) — the copy is in
        // effect the migration tool this project deliberately has no other one of.
        let samplesDst  = destFolder.appendingPathComponent("samples", isDirectory: true)
        let sourcesDst  = samplesDst.appendingPathComponent("sources", isDirectory: true)
        let consolidateDst  = samplesDst.appendingPathComponent("consolidate", isDirectory: true)
        let waveformsDst = destFolder.appendingPathComponent("waveforms", isDirectory: true)

        // 1) Discovery (transitive closure through the sidecars).
        var sourceFiles: Set<String> = []          // absolute paths of the source `.clip`s
        var objectSidecars: [UUID: SoundObject] = [:]    // defID → original sub-tree
        var referencedDefIDs: Set<UUID> = []
        var missing: [String] = []

        func discover(_ o: SoundObject) {
            if let defID = o.consolidateID {
                referencedDefIDs.insert(defID)
                return   // an instance reads the baked wave; the recursion goes through the definition
            }
            switch o.kind {
            case .clip(let fp, _, _, _, _):
                sourceFiles.insert(fp)
            case .group(let children, _):
                children.forEach(discover)
            case .aux, .midiClip:
                break
            }
        }

        items.forEach(discover)

        // Closure over the definitions reached (a definition can hold others through its
        // sidecar → we iterate until it stabilises).
        var processedDefs: Set<UUID> = []
        while let defID = referencedDefIDs.subtracting(processedDefs).first {
            processedDefs.insert(defID)
            guard let def = consolidateDefinitions[defID] else {
                missing.append(L("saveCopy.missingConsolidate", String(defID.uuidString.prefix(8))))
                continue
            }
            if let original = readConsolidateSidecar(def.wave, definition: defID) {
                objectSidecars[defID] = original
                discover(original)
            } else {
                missing.append(consolidateSidecarName(def.wave))
            }
        }

        // 2) The source files' copy plan + a map from original path → new path.
        var pathMap: [String: String] = [:]     // key = standardised source path
        var fileCopies: [(src: URL, dst: URL)] = []
        var waveformCopies: [(src: URL, dst: URL)] = []   // `.wfc` caches (a regenerable cache, silent)
        var usedSourceNames: Set<String> = []
        let fm = FileManager.default

        // Copies the `<basename>.wfc` waveform cache of an included file, renamed to follow the
        // (de-duplicated) name inside the capsule. `copyItem` preserves size + mtime → the `.wfc`
        // header (validated on the source's size + mtime) stays valid on the recipient's side, who
        // sees the waveforms with no recomputation. No cache ⇒ skipped (recomputed on opening).
        let wfSrcDir = waveformsFolder
        func addWaveformCopy(originalBasename: String, destBasename: String) {
            guard let wfSrcDir else { return }
            let wfSrc = wfSrcDir.appendingPathComponent("\(originalBasename).wfc")
            guard fm.fileExists(atPath: wfSrc.path) else { return }
            waveformCopies.append((wfSrc, waveformsDst.appendingPathComponent("\(destBasename).wfc")))
        }

        func uniqueSourceName(for fp: String) -> String {
            let url = URL(fileURLWithPath: fp)
            let ext = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            var candidate = url.lastPathComponent
            var i = 2
            while usedSourceNames.contains(candidate) {
                candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
                i += 1
            }
            usedSourceNames.insert(candidate)
            return candidate
        }

        for fp in sourceFiles.sorted() {
            let srcURL = URL(fileURLWithPath: fp)
            guard fm.fileExists(atPath: srcURL.path) else {
                missing.append(srcURL.lastPathComponent)
                continue   // the link is left as it is in the copy (its original path)
            }
            let name = uniqueSourceName(for: fp)
            let dstURL = sourcesDst.appendingPathComponent(name)
            pathMap[srcURL.standardizedFileURL.path] = dstURL.path
            fileCopies.append((srcURL, dstURL))
            addWaveformCopy(originalBasename: srcURL.lastPathComponent, destBasename: name)
        }

        // 3) Consolidated-object waves: copied from WHEREVER each is actually found (cas E1/E6 —
        //    samples/consolidate/, the legacy samples/objects/, or the Q3 fallback) into the
        //    capsule's samples/consolidate/. The copy is what normalises a mixed project.
        if projectFolder != nil {
            for defID in processedDefs {
                guard let def = consolidateDefinitions[defID],
                      let srcFolder = consolidateReadFolder(forWave: def.wave, definition: defID) else { continue }
                let srcWave = srcFolder.appendingPathComponent(def.wave)
                if fm.fileExists(atPath: srcWave.path) {
                    fileCopies.append((srcWave, consolidateDst.appendingPathComponent(def.wave)))
                    addWaveformCopy(originalBasename: def.wave, destBasename: def.wave)
                } else {
                    missing.append(def.wave)
                }
            }
        }

        // 4) Rewriting a sub-tree's paths: instance → the copy's objects/, source →
        //    the copy's sources/ (through `pathMap`). Applied to the items AND to each sidecar.
        func rewrite(_ o: SoundObject) -> SoundObject {
            var n = o
            if let defID = o.consolidateID, let def = consolidateDefinitions[defID],
               case .clip(_, let so, let fd, let sr, let rev) = o.kind {
                n.kind = .clip(filePath: consolidateDst.appendingPathComponent(def.wave).path,
                               sourceOffset: so, fileDuration: fd, speedRatio: sr, isReversed: rev)
            } else {
                switch o.kind {
                case .clip(let fp, let so, let fd, let sr, let rev):
                    let newPath = pathMap[URL(fileURLWithPath: fp).standardizedFileURL.path] ?? fp
                    n.kind = .clip(filePath: newPath, sourceOffset: so, fileDuration: fd,
                                   speedRatio: sr, isReversed: rev)
                case .group(let children, let e):
                    n.kind = .group(children: children.map(rewrite), isExpanded: e)
                case .aux, .midiClip:
                    break
                }
            }
            return n
        }

        // 5) The rewritten sidecars, to be written into the capsule.
        var sidecarWrites: [(dst: URL, data: Data)] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for (defID, original) in objectSidecars {
            guard let def = consolidateDefinitions[defID],
                  let data = try? encodedConsolidateSidecar(rewrite(original), projectFolder: destFolder)
            else { continue }
            sidecarWrites.append((consolidateSidecarURL(forWave: def.wave, in: consolidateDst), data))
        }

        // 6) The project document: items (with captured plugin states) rewritten + the definition
        //    registry filtered down to the closure (orphan definitions are dropped).
        let rewrittenItems = portableItems(itemsWithCapturedPluginStates().map(rewrite),
                                           projectFolder: destFolder)
        let closureDefs = processedDefs.compactMap { consolidateDefinitions[$0] }
        // The SAME document as a save (@see projectDocument): snap, viewport, tempo, grid and the
        // annotations travel with the copy — only the items (paths rewritten) and the registry
        // (filtered down to the closure: orphan definitions are dropped) are the copy's own.
        let doc = projectDocument(items: rewrittenItems, consolidateDefinitions: closureDefs)
        let projectData: Data
        do {
            projectData = try encoder.encode(doc)
        } catch {
            copyAlert(success: false,
                      info: L("saveCopy.encodeFailed", error.localizedDescription))
            completion?(SaveCopyReport(projectFile: projectFileURL, copiedFiles: 0,
                                       missing: missing,
                                       errors: [error.localizedDescription]))
            return
        }

        // Folders to create (waveforms/ empty: a cache the recipient can regenerate).
        let dirsToCreate = [destFolder, samplesDst, sourcesDst, consolidateDst, waveformsDst]

        // 7) File I/O in the background, then the report on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var ioErrors: [String] = []

            for dir in dirsToCreate {
                do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
                catch { ioErrors.append(L("saveCopy.error.folder", dir.lastPathComponent,
                                          error.localizedDescription)) }
            }
            // The last line of defence, below the folder check: a destination file that IS its
            // source (a clip whose source already sits in the destination's samples/sources/,
            // reached through another spelling of the same path) is left alone — removing it
            // "to replace it" would delete the one copy there is. It is already where it belongs.
            for (src, dst) in fileCopies {
                if FolderIdentity.same(src, dst) { continue }
                do {
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.copyItem(at: src, to: dst)
                } catch {
                    ioErrors.append("\(src.lastPathComponent) : \(error.localizedDescription)")
                }
            }
            // Waveform caches: regenerable → a failure does not invalidate the copy (silent).
            for (src, dst) in waveformCopies {
                if FolderIdentity.same(src, dst) { continue }
                if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                try? fm.copyItem(at: src, to: dst)
            }
            for (dst, data) in sidecarWrites {
                do { try data.write(to: dst, options: .atomic) }
                catch { ioErrors.append("\(dst.lastPathComponent) : \(error.localizedDescription)") }
            }
            do { try projectData.write(to: projectFileURL, options: .atomic) }
            catch { ioErrors.append("\(projectFileURL.lastPathComponent) : \(error.localizedDescription)") }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if ioErrors.isEmpty {
                    self.copyAlert(success: true, info: self.copySummary(destFolder: destFolder,
                                                                         copied: fileCopies.count,
                                                                         missing: missing))
                } else {
                    self.copyAlert(success: false,
                                   info: L("saveCopy.writeErrors") + "\n"
                                        + self.truncatedList(ioErrors))
                }
                completion?(SaveCopyReport(projectFile: projectFileURL,
                                           copiedFiles: fileCopies.count,
                                           missing: missing, errors: ioErrors))
            }
        }
    }

    // MARK: - Reading the source sidecars (the project's current folders)

    private func readConsolidateSidecar(_ wave: String, definition defID: UUID? = nil) -> SoundObject? {
        // Cas E4: read where the wave was actually found, not assumed to be the write folder.
        guard let folder = consolidateReadFolder(forWave: wave, definition: defID) else { return nil }
        let url = consolidateSidecarURL(forWave: wave, in: folder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decodedConsolidateSidecar(data, projectFolder: projectFolder)
    }

    private func consolidateSidecarName(_ wave: String) -> String {
        "\((wave as NSString).deletingPathExtension)_objectstate.json"
    }

    // MARK: - Report

    private func truncatedList(_ items: [String], max: Int = 12) -> String {
        let shown = items.prefix(max).map { "• \($0)" }.joined(separator: "\n")
        return items.count > max ? shown + "\n" + L("saveCopy.andMore", items.count - max) : shown
    }

    private func copySummary(destFolder: URL, copied: Int, missing: [String]) -> String {
        var s = Ln("saveCopy.summary", copied, destFolder.lastPathComponent, copied)
        if !missing.isEmpty {
            s += "\n\n" + L("saveCopy.summary.missing") + "\n" + truncatedList(missing)
        }
        return s
    }

    private func copyAlert(success: Bool, info: String) {
        notify(success ? L("saveCopy.done.title") : L("saveCopy.failed.title"), info,
               style: success ? .informational : .warning)
    }
}

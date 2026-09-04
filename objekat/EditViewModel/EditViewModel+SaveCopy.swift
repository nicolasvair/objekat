import AppKit

// MARK: - Save a copy with audio files (a self-contained capsule)
//
// Creates a SELF-CONTAINED project folder holding the project + ALL the audio files it needs,
// and NOTHING more (the orphan waves piled up in samples/objects/ after a re-bake are
// excluded). Used to send a "ready to open" copy to somebody else.
//
// A reminder of the model: the SOURCE files of a normal `.clip` point at an EXTERNAL absolute
// path (Sound library/Finder) — they are not in the project folder. Only sound-object waves
// (samples/objects/) live there, each with a JSON sidecar
// (`*_objectstate.json`) carrying the editable sub-tree. Those sidecars themselves reference
// other files (sources, nested sound objects) → they are collected by transitive closure
// so that the recipient can open AND edit everything.

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
            self.performSaveCopy(to: dest)
        }
    }

    // MARK: - Carrying it out

    /// Prepares the copy (capturing plugin states + discovery + rewriting paths, on the main
    /// thread), then does the file I/O in the background and reports the result.
    ///
    /// Internal (and not private): this is the AppKit-free heart of "Save a copy", the one external
    /// driving will call directly, skipping the panel but not a single line of the copying
    /// logic.
    func performSaveCopy(to destFolder: URL) {
        let folderName = destFolder.lastPathComponent
        let projectFileURL = destFolder.appendingPathComponent("\(folderName).objekat.json")

        // Destination folders.
        let samplesDst  = destFolder.appendingPathComponent("samples", isDirectory: true)
        let sourcesDst  = samplesDst.appendingPathComponent("sources", isDirectory: true)
        let objectsDst  = samplesDst.appendingPathComponent("objects", isDirectory: true)
        let waveformsDst = destFolder.appendingPathComponent("waveforms", isDirectory: true)

        // 1) Discovery (transitive closure through the sidecars).
        var sourceFiles: Set<String> = []          // absolute paths of the source `.clip`s
        var objectSidecars: [UUID: SoundObject] = [:]    // defID → original sub-tree
        var referencedDefIDs: Set<UUID> = []
        var missing: [String] = []

        func discover(_ o: SoundObject) {
            if let defID = o.definitionID {
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
            guard let def = objectDefinitions[defID] else {
                missing.append(L("saveCopy.missingDefinition", String(defID.uuidString.prefix(8))))
                continue
            }
            if let original = readObjectSidecar(def.wave) {
                objectSidecars[defID] = original
                discover(original)
            } else {
                missing.append(objectSidecarName(def.wave))
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

        // 3) Sound-object waves: copied from the CURRENT folder into the capsule.
        if let objects = objectsFolder {
            for defID in processedDefs {
                guard let def = objectDefinitions[defID] else { continue }
                let srcWave = objects.appendingPathComponent(def.wave)
                if fm.fileExists(atPath: srcWave.path) {
                    fileCopies.append((srcWave, objectsDst.appendingPathComponent(def.wave)))
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
            if let defID = o.definitionID, let def = objectDefinitions[defID],
               case .clip(_, let so, let fd, let sr, let rev) = o.kind {
                n.kind = .clip(filePath: objectsDst.appendingPathComponent(def.wave).path,
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
            guard let def = objectDefinitions[defID],
                  let data = try? encodedObjectSidecar(rewrite(original), projectFolder: destFolder)
            else { continue }
            sidecarWrites.append((objectSidecarURL(forWave: def.wave, in: objectsDst), data))
        }

        // 6) The project document: items (with captured plugin states) rewritten + the definition
        //    registry filtered down to the closure (orphan definitions are dropped).
        let rewrittenItems = portableItems(itemsWithCapturedPluginStates().map(rewrite),
                                           projectFolder: destFolder)
        let closureDefs = processedDefs.compactMap { objectDefinitions[$0] }
        let doc = ProjectDocument(items: rewrittenItems,
                                  stems: stems,
                                  tempo: tempo,
                                  timeSigNumerator: timeSigNumerator,
                                  timeSigDenominator: timeSigDenominator,
                                  gridMode: gridMode,
                                  objectDefinitions: closureDefs.isEmpty ? nil : closureDefs)
        let projectData: Data
        do {
            projectData = try encoder.encode(doc)
        } catch {
            copyAlert(success: false,
                      info: L("saveCopy.encodeFailed", error.localizedDescription))
            return
        }

        // Folders to create (waveforms/ empty: a cache the recipient can regenerate).
        let dirsToCreate = [destFolder, samplesDst, sourcesDst, objectsDst, waveformsDst]

        // 7) File I/O in the background, then the report on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var ioErrors: [String] = []

            for dir in dirsToCreate {
                do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
                catch { ioErrors.append(L("saveCopy.error.folder", dir.lastPathComponent,
                                          error.localizedDescription)) }
            }
            for (src, dst) in fileCopies {
                do {
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.copyItem(at: src, to: dst)
                } catch {
                    ioErrors.append("\(src.lastPathComponent) : \(error.localizedDescription)")
                }
            }
            // Waveform caches: regenerable → a failure does not invalidate the copy (silent).
            for (src, dst) in waveformCopies {
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
            }
        }
    }

    // MARK: - Reading the source sidecars (the project's current folders)

    private func readObjectSidecar(_ wave: String) -> SoundObject? {
        guard let objects = objectsFolder else { return nil }
        let url = objectSidecarURL(forWave: wave, in: objects)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decodedObjectSidecar(data, projectFolder: projectFolder)
    }

    private func objectSidecarName(_ wave: String) -> String {
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

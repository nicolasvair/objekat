import Foundation

// MARK: - Archiving the project's audio: WAV → FLAC, lossless, the paths follow
//
// For sending or filing a project: every WAV of the PROJECT FOLDER that the project reads — the
// consolidated objects' rendered waves and the sources embedded in `samples/sources/` — becomes a
// FLAC next to it, and the project is re-aimed onto it. The popover of the unused-files clean-up
// (`DiskUsagePopoverView`) is the door; `project.convert_to_flac` is the same function for a script.
//
// THE LOSSLESS RULE lives in `FlacConverter` (@see its head): integer 16/24 → FLAC of the same
// depth (exact); floating point → FLAC 24 ONLY if its peak is ≤ 0 dBFS, otherwise it stays a WAV and
// is REPORTED; more than 8 channels, another depth, an unreadable file → stays a WAV, reported.
//
// WHAT IS NEVER TOUCHED:
//   • a file OUTSIDE the project folder (the sound library, the Finder's drops): only counted;
//   • the ORIGINAL WAV. It is not deleted here. The FLAC is written beside it, read back and
//     compared with it (`FlacConverter.archive`) BEFORE anything points at it; and the version file
//     on disk still names the WAV until the project is saved, so removing it now would break a
//     project closed without saving. After the save the WAV is read by nobody — the clean-up
//     already offers it, with the Trash behind it. `FlacConverter.archive` also refuses to
//     overwrite a file that is already there unless it is the same sound.
//   • a source that a consolidated object's CONTENT reads (its sidecar names that path, and the
//     sidecars are not rewritten): it stays a WAV, said.
//   • a source carrying an ARA retouch (Melodyne reads the file it analysed).
//
// The project is marked MODIFIED; there is no undo point (the originals are still on disk, so an
// undo that goes back before the conversion still finds its WAVs).

// MARK: - Values (the part that runs off the main thread)

nonisolated enum FlacArchive {

    /// Why a file stays a WAV.
    enum Reason: Equatable, Sendable {
        case converter(FlacConverter.KeepReason)
        /// A consolidated object's sidecar (its editable content) names this very path.
        case readByConsolidatedContent
        /// A clip with an ARA source reads it.
        case araSource
    }

    enum Verdict: Equatable, Sendable {
        /// Converted (or, in a dry run, convertible) at `bits`. `bytesAfter` is nil in a dry run.
        case convert(bits: Int, bytesBefore: Int64, bytesAfter: Int64?)
        case keep(Reason)
    }

    /// One WAV of the project folder the archive looked at.
    struct Candidate: Equatable, Sendable {
        /// The canonical path of the WAV (symbolic links resolved) — what clips are matched on.
        var key: String
        var url: URL
        var destination: URL
        /// Relative to the project folder.
        var rel: String
        /// The consolidated definitions whose wave it is.
        var defIDs: [UUID]
        /// A clip of the project (or of a sidecar) reads it as a source.
        var isSource: Bool
        /// Known without looking at the file: it stays a WAV.
        var forced: Reason?
    }

    struct Entry: Equatable, Sendable {
        var candidate: Candidate
        var verdict: Verdict
    }

    /// What the main thread hands over: values only.
    struct Input: Sendable {
        var folder: URL
        var roots: DiskUsageRoots
        /// Where each definition's wave is ACTUALLY found (the file may not be there).
        var defWaves: [UUID: URL]
        /// The canonical paths of the clips that carry an ARA source.
        var araKeys: Set<String>
    }

    struct Gathered: Sendable {
        var candidates: [Candidate]
        /// WAVs the project reads that live OUTSIDE its folder: untouched, only counted.
        var outside: Int
    }

    // MARK: Gathering

    static func isWav(_ url: URL) -> Bool { url.pathExtension.lowercased() == "wav" }

    /// The WAVs the project folder holds AND the project reads. Reads sidecars (disk): off the
    /// main thread.
    static func gather(_ input: Input) -> Gathered {
        let folder = input.folder
        let folderKey = DiskUsageScanner.realPath(folder.path)
        let prefix = folderKey.hasSuffix("/") ? folderKey : folderKey + "/"
        let fm = FileManager.default

        let roots = input.roots
        let reader = DiskUsageScanner.sidecarReader(roots)
        let closure = ProjectFileUsage.closure(items: roots.items, defs: roots.defs, readSidecar: reader)

        func url(forSource path: String) -> URL {
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
        }

        // The sources the CONTENT of a consolidated object reads: the closure of the definitions
        // alone, with no item of the session.
        let contentClosure = ProjectFileUsage.closure(
            items: closure.visitedDefinitions.map { ProjectFileUsage.Ref(consolidateID: $0) },
            defs: roots.defs, readSidecar: reader)
        var contentKeys = Set<String>()
        for p in contentClosure.sourcePaths where !p.isEmpty {
            contentKeys.insert(DiskUsageScanner.realPath(url(forSource: p).path))
        }

        var byKey: [String: Candidate] = [:]
        var order: [String] = []
        var outsideKeys = Set<String>()

        func add(_ file: URL, defID: UUID?, isSource: Bool) {
            guard isWav(file), fm.fileExists(atPath: file.path) else { return }
            let key = DiskUsageScanner.realPath(file.path)
            guard key.hasPrefix(prefix) else {
                outsideKeys.insert(key)      // counted once per file, however many things read it
                return
            }
            if var c = byKey[key] {
                if let defID, !c.defIDs.contains(defID) { c.defIDs.append(defID) }
                c.isSource = c.isSource || isSource
                byKey[key] = c
                return
            }
            var forced: Reason?
            if isSource, contentKeys.contains(key) { forced = .readByConsolidatedContent }
            if isSource, input.araKeys.contains(key) { forced = .araSource }
            byKey[key] = Candidate(key: key, url: file,
                                   destination: file.deletingPathExtension().appendingPathExtension("flac"),
                                   rel: String(key.dropFirst(prefix.count)),
                                   defIDs: defID.map { [$0] } ?? [], isSource: isSource, forced: forced)
            order.append(key)
        }

        for path in closure.sourcePaths.sorted() where !path.isEmpty {
            add(url(forSource: path), defID: nil, isSource: true)
        }
        for id in closure.visitedDefinitions {
            guard roots.defs[id] != nil, let wave = input.defWaves[id] else { continue }
            add(wave, defID: id, isSource: false)
        }
        return Gathered(candidates: order.compactMap { byKey[$0] }, outside: outsideKeys.count)
    }

    // MARK: Running

    /// Looks at (`dryRun`) or converts each candidate. Blocking: off the main thread.
    static func run(_ candidates: [Candidate], dryRun: Bool, isCancelled: () -> Bool = { false }) -> [Entry] {
        let fm = FileManager.default
        func size(_ u: URL) -> Int64 {
            ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var out: [Entry] = []
        for c in candidates {
            if let forced = c.forced { out.append(Entry(candidate: c, verdict: .keep(forced))); continue }
            if dryRun {
                switch FlacConverter.plan(of: c.url, isCancelled: isCancelled) {
                case .convert(let bits):
                    out.append(Entry(candidate: c, verdict: .convert(bits: bits, bytesBefore: size(c.url), bytesAfter: nil)))
                case .keep(let reason):
                    out.append(Entry(candidate: c, verdict: .keep(.converter(reason))))
                }
            } else {
                switch FlacConverter.archive(source: c.url, destination: c.destination, isCancelled: isCancelled) {
                case .converted(let bits, let before, let after):
                    out.append(Entry(candidate: c, verdict: .convert(bits: bits, bytesBefore: before, bytesAfter: after)))
                case .kept(let reason):
                    out.append(Entry(candidate: c, verdict: .keep(.converter(reason))))
                }
            }
        }
        return out
    }
}

// MARK: - The outcome

enum FlacArchiveRefusal: Equatable {
    /// The project was never saved: it has no folder.
    case unsaved
    /// Something forbids it now (an i18n key names what).
    case busy(String)
    /// The project in front changed while the files were being converted.
    case projectChanged

    var apiCode: String {
        switch self {
        case .unsaved: return "unsaved"
        case .busy: return "busy"
        case .projectChanged: return "project_changed"
        }
    }
}

struct FlacArchiveOutcome {
    var dryRun: Bool
    var refusal: FlacArchiveRefusal?
    var entries: [FlacArchive.Entry] = []
    /// WAVs read by the project that live outside its folder: not touched.
    var outside = 0
    /// Clips (and consolidated placements) re-aimed onto a FLAC.
    var rebound = 0

    var converted: [FlacArchive.Entry] { entries.filter { if case .convert = $0.verdict { return true } else { return false } } }
    var kept: [FlacArchive.Entry] { entries.filter { if case .keep = $0.verdict { return true } else { return false } } }
    var bytesBefore: Int64 {
        converted.reduce(0) { if case .convert(_, let b, _) = $1.verdict { return $0 + b } else { return $0 } }
    }
    var bytesAfter: Int64 {
        converted.reduce(0) { if case .convert(_, _, let a?) = $1.verdict { return $0 + a } else { return $0 } }
    }
}

// MARK: - The view-model's side (main thread)

extension EditViewModel {

    /// What forbids the conversion right now (an i18n key), nil if nothing does. The disk-usage
    /// reasons (a load, a render, an edit of a consolidated object) plus a running export, which
    /// reads the very files that would be re-aimed.
    var flacArchiveBusyKey: String? {
        if isArchivingToFlac { return "flacArchive.busy.running" }
        return flacArchiveForeignBusyKey
    }

    /// The same, without the conversion's own flag (what the end of a conversion asks again).
    private var flacArchiveForeignBusyKey: String? {
        if exportJob?.isRunning == true || exportBatch?.isActive == true { return "diskUsage.busy.render" }
        return diskUsageBaseBusyKey
    }

    private func makeFlacArchiveInput() -> FlacArchive.Input? {
        guard let folder = projectFolder else { return nil }
        var defWaves: [UUID: URL] = [:]
        for (id, def) in consolidateDefinitions {
            if let url = consolidateWaveURL(def.wave, forConsolidate: id) { defWaves[id] = url }
        }
        var ara = Set<String>()
        func walk(_ list: [SoundObject]) {
            for o in list {
                switch o.kind {
                case .clip(let path, _, _, _, _):
                    if o.araSource != nil, !path.isEmpty { ara.insert(DiskUsageScanner.realPath(path)) }
                case .group(let children, _): walk(children)
                case .aux, .midiClip: break
                }
            }
        }
        walk(items)
        return FlacArchive.Input(folder: folder, roots: diskUsageSessionRoots(), defWaves: defWaves, araKeys: ara)
    }

    /// Converts (or, with `dryRun`, only looks at) the WAVs of the project folder that the project
    /// reads — @see the head of this file for the rule and for what is never touched.
    ///
    /// A dry run moves nothing and writes nothing; it reads the floating-point files to find their
    /// peak, which is what decides them.
    @discardableResult
    func convertAudioToFlac(dryRun: Bool) async -> FlacArchiveOutcome {
        var outcome = FlacArchiveOutcome(dryRun: dryRun)
        guard projectFolder != nil, projectURL != nil else { outcome.refusal = .unsaved; return outcome }
        if let busy = flacArchiveBusyKey { outcome.refusal = .busy(busy); return outcome }
        guard let input = makeFlacArchiveInput() else { outcome.refusal = .unsaved; return outcome }

        let token = projectLoadToken
        let url = projectURL
        isArchivingToFlac = true
        defer { isArchivingToFlac = false }

        let (entries, outside) = await Task.detached(priority: .utility) { () -> ([FlacArchive.Entry], Int) in
            let gathered = FlacArchive.gather(input)
            return (FlacArchive.run(gathered.candidates, dryRun: dryRun), gathered.outside)
        }.value
        outcome.entries = entries
        outcome.outside = outside
        guard !dryRun else { return outcome }

        // The files exist now; whatever the project is, it must still be the one they belong to.
        guard projectLoadToken == token, projectURL == url, flacArchiveForeignBusyKey == nil else {
            outcome.refusal = .projectChanged
            return outcome
        }
        applyFlacArchive(&outcome)
        return outcome
    }

    /// Points the project at the FLACs that were written and verified.
    private func applyFlacArchive(_ outcome: inout FlacArchiveOutcome) {
        let fm = FileManager.default
        var changed = false
        for index in outcome.entries.indices {
            let entry = outcome.entries[index]
            guard case .convert = entry.verdict else { continue }
            let c = entry.candidate
            guard fm.fileExists(atPath: c.destination.path) else { continue }
            var failure: String?

            for defID in c.defIDs {
                // Only a definition still on THAT wave: a re-bake during the conversion moved it on.
                guard consolidateDefinitions[defID]?.wave == c.url.lastPathComponent else { continue }
                if rebindConsolidateWave(defID: defID, to: c.destination) {
                    outcome.rebound += placementIDs(forConsolidate: defID).count
                    changed = true
                } else {
                    failure = "the FLAC could not be opened"
                }
            }
            if c.isSource {
                let length = audioFileDuration(c.destination)
                let bytes = ((try? fm.attributesOfItem(atPath: c.destination.path))?[.size] as? NSNumber)?.int64Value
                for id in flacArchiveClipIDs(readingKey: c.key) {
                    if relaunchClip(id: id, onFile: c.destination.path, fileLength: length, size: bytes,
                                    capturingLiveState: true) {
                        outcome.rebound += 1
                        changed = true
                    }
                }
            }
            if let failure {
                outcome.entries[index].verdict = .keep(.converter(.encodeFailed(failure)))
            }
        }
        if changed { isDirty = true }
        rescanMissingFiles()
        refreshDiskUsage()
    }

    /// The clips (not the placements of a consolidated object) that read the file `key` as a source.
    private func flacArchiveClipIDs(readingKey key: String) -> [UUID] {
        var found: [UUID] = []
        func walk(_ list: [SoundObject]) {
            for o in list {
                switch o.kind {
                case .clip(let path, _, _, _, _):
                    if o.consolidateID == nil, o.araSource == nil, !path.isEmpty,
                       DiskUsageScanner.realPath(path) == key { found.append(o.id) }
                case .group(let children, _): walk(children)
                case .aux, .midiClip: break
                }
            }
        }
        walk(items)
        return found
    }
}

// MARK: - The words (for the popover; the API speaks English on its own)

extension FlacArchiveOutcome {

    /// "<name> : <why it stays a WAV>" for each file left as it was.
    var keptLines: [String] {
        kept.compactMap { entry in
            guard case .keep(let reason) = entry.verdict else { return nil }
            let name = entry.candidate.rel
            switch reason {
            case .readByConsolidatedContent: return L("flacArchive.reason.content", name)
            case .araSource: return L("flacArchive.reason.ara", name)
            case .converter(let r):
                switch r {
                case .floatOverFullScale(let db): return L("flacArchive.reason.overFullScale", name, String(format: "%+.1f", db))
                case .tooManyChannels(let n): return L("flacArchive.reason.channels", name, n)
                case .unsupportedDepth(let d): return L("flacArchive.reason.depth", name, d)
                case .unreadable(let d): return L("flacArchive.reason.unreadable", name, d)
                case .empty: return L("flacArchive.reason.empty", name)
                case .encodeFailed(let d): return L("flacArchive.reason.failed", name, d)
                }
            }
        }
    }

    /// The text of the report after a real conversion.
    var summaryText: String {
        var lines: [String] = []
        if converted.isEmpty {
            lines.append(L("flacArchive.none"))
        } else {
            lines.append(L("flacArchive.summary", converted.count,
                           DiskUsageFormat.bytes(bytesBefore), DiskUsageFormat.bytes(bytesAfter)))
            lines.append(L("flacArchive.next"))
        }
        if !kept.isEmpty {
            lines.append("")
            lines.append(L("flacArchive.kept", kept.count))
            lines += keptLines.prefix(12).map { "• " + $0 }
            if keptLines.count > 12 { lines.append(L("flacArchive.more", keptLines.count - 12)) }
        }
        if outside > 0 { lines.append(""); lines.append(L("flacArchive.outside", outside)) }
        return lines.joined(separator: "\n")
    }
}

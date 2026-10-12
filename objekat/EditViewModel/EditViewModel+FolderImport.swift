import Foundation
import AVFoundation

// MARK: - Importing a folder as a group (the model's half)
//
// The rules — what is read, in which order, how it is laid out, how big a group is — live in
// `FolderImport`, which knows no model. This file is the other half: it reads the disk and the
// files' lengths (off the main thread), turns the plan into `SoundObject`s, and lays them down
// through the very doors a dropped file uses (`placeClip`, `add`, `addChild`, `resolveOverlaps`),
// so a folder lands exactly where a file would have, in the same gesture.
//
// Two callers share `placeDropEntries`: the timeline's drop (which pushes its own undo point, one
// for the whole drop) and the `object.import_folder` command (whose undo point the bus pushes).

extension EditViewModel {

    // MARK: What a drop hands over

    /// One thing dropped, resolved and measured: a file, or a folder already read down to its leaves.
    enum DropEntry: Sendable {
        case file(FolderImport.FileEntry)
        case folder(FolderImport.Node)

        /// The room it takes on the timeline, in seconds. A folder takes the span of the group it
        /// becomes, which depends on how that group is laid out inside (`mode`).
        func duration(mode: FolderImport.Mode) -> Double {
            switch self {
            case .file(let f):   return f.duration
            case .folder(let n): return FolderImport.duration(of: n, mode: mode)
            }
        }

        var fileCount: Int {
            switch self {
            case .file:          return 1
            case .folder(let n): return n.fileCount
            }
        }
    }

    /// A folder that could not be turned into a group, with the reason (for the message).
    struct FolderRefusal: Sendable {
        let name: String
        let failure: FolderImport.Failure
    }

    /// The outcome of resolving what was dropped.
    struct DropLoad: Sendable {
        var entries: [DropEntry] = []
        var refusals: [FolderRefusal] = []
        /// Sub-folders left out for sitting below `FolderImport.maxDepth`.
        var omittedDeepFolders = 0
        var fileCount: Int { entries.reduce(0) { $0 + $1.fileCount } }
        /// (Explicit: the implicit one would be main-actor like the rest of the model, and the loader
        /// that builds this is not.)
        nonisolated init() {}
    }

    /// A drop's layout mode in the folder import's own vocabulary.
    static func folderMode(of mode: FileDropMode) -> FolderImport.Mode {
        mode == .sequential ? .sequential : .stacked
    }

    // MARK: Reading the disk (off the main thread)

    nonisolated static func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// An audio file's length. The same fallback as everywhere a file is laid down: if the read
    /// fails the object is 5 s long and stays resizable, rather than the import being refused.
    nonisolated static func readAudioDuration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let s = CMTimeGetSeconds(try await asset.load(.duration))
            return (s.isNaN || s <= 0) ? 5.0 : s
        } catch {
            return 5.0
        }
    }

    /// Lengths and sizes of `urls`, in the SAME order, a few reads at a time: a folder of two
    /// thousand takes would otherwise open two thousand assets at once.
    nonisolated static func measureFiles(_ urls: [URL],
                                         width: Int = 8) async -> [(duration: Double, size: Int64?)] {
        var out = [(duration: Double, size: Int64?)](repeating: (5.0, nil), count: urls.count)
        guard !urls.isEmpty else { return out }
        await withTaskGroup(of: (Int, Double, Int64?).self) { group in
            var next = 0
            func launch() {
                guard next < urls.count else { return }
                let i = next
                next += 1
                let url = urls[i]
                group.addTask { (i, await readAudioDuration(url), fileSize(atPath: url.path)) }
            }
            for _ in 0..<min(width, urls.count) { launch() }
            while let (i, duration, size) = await group.next() {
                out[i] = (duration, size)
                launch()
            }
        }
        return out
    }

    /// The folder's tree, read WITHOUT its lengths (cheap: listings only). Used on its own by the
    /// hover, which only needs the shape and the count.
    nonisolated static func scanFolder(_ url: URL) async -> FolderImport.ScanResult {
        await Task.detached(priority: .userInitiated) {
            FolderImport.scan(root: url, list: FolderImport.diskListing,
                              isAudio: { SoundLibraryViewModel.audioExts.contains($0) })
        }.value
    }

    /// The folder's tree with every file measured, ready to be planned.
    nonisolated static func loadFolder(_ url: URL) async -> FolderImport.ScanResult {
        var scan = await scanFolder(url)
        guard let root = scan.root else { return scan }
        let measures = await measureFiles(FolderImport.fileURLs(of: root))
        scan.root = FolderImport.filling(root, with: measures)
        return scan
    }

    /// Resolves what a drop (or a command) hands over, IN ITS ORDER: a file is measured, a folder
    /// is read down to its leaves and measured. The files' lengths are read together (a few at a
    /// time), as a plain multiple drop always did.
    nonisolated static func loadDropEntries(from urls: [URL]) async -> DropLoad {
        // The plain files first, all measured in ONE pass (same behaviour as before folders existed);
        // the folders one by one (each is a read in itself).
        let fileIndexes = urls.indices.filter { !isDirectoryURL(urls[$0]) }
        let measures = await measureFiles(fileIndexes.map { urls[$0] })
        var measuredByIndex: [Int: (duration: Double, size: Int64?)] = [:]
        for (k, i) in fileIndexes.enumerated() { measuredByIndex[i] = measures[k] }

        var load = DropLoad()
        for (i, url) in urls.enumerated() {
            if let m = measuredByIndex[i] {
                load.entries.append(.file(FolderImport.FileEntry(url: url, duration: m.duration, size: m.size)))
                continue
            }
            let scan = await loadFolder(url)
            load.omittedDeepFolders += scan.omittedDeepFolders
            if let root = scan.root {
                load.entries.append(.folder(root))
            } else if let failure = scan.failure {
                load.refusals.append(FolderRefusal(name: url.lastPathComponent, failure: failure))
            }
        }
        return load
    }

    // MARK: Plan → objects

    /// The clip a planned file becomes. The size is recorded as it is laid down: what settles two
    /// homonyms the day this link breaks and a folder is swept for it (@see EditViewModel+Relink).
    static func clipObject(for entry: FolderImport.FileEntry, start: Double, lane: Int) -> SoundObject {
        var obj = SoundObject(
            id: UUID(),
            startTime: start,
            duration: entry.duration,
            lane: lane,
            volume: 0.0,
            pan: 0.0,
            kind: .clip(filePath: entry.url.path,
                        sourceOffset: 0,
                        fileDuration: entry.duration,
                        speedRatio: 1.0,
                        isReversed: false)
        )
        obj.fileSize = entry.size ?? fileSize(atPath: entry.url.path)
        return obj
    }

    /// The group a planned folder becomes, FOLDED, and its sub-folders likewise: children in
    /// absolute time, lanes relative to their group (the model's convention, @see createGroup).
    /// Named after the folder; the bounds are the plan's — the union of what is inside.
    static func groupObject(for planned: FolderImport.PlannedGroup) -> SoundObject {
        let children: [SoundObject] = planned.items.map { item in
            switch item {
            case .file(let f):   return clipObject(for: f.entry, start: f.start, lane: f.lane)
            case .group(let g):  return groupObject(for: g)
            }
        }
        return SoundObject(
            id: UUID(),
            startTime: planned.start,
            duration: planned.duration,
            lane: planned.lane,
            label: planned.name.isEmpty ? nil : planned.name,
            kind: .group(children: children, isExpanded: false)
        )
    }

    // MARK: Laying down

    /// Lays the entries down in ONE gesture, in the order given, according to `mode`: the same
    /// layout as a multiple file drop (`fileDropLayout`) with a folder counting as one entry. The
    /// first goes through `placeClip` (it decides whether the target lane falls inside an open group
    /// and converts display → base lane ONCE); the others follow in the same container.
    ///
    /// Does NOT push an undo point: the caller did, before this. Returns the ids of what was laid
    /// down at the level it landed on, in order.
    @discardableResult
    func placeDropEntries(_ entries: [DropEntry], baseLane: Int, baseStart: Double,
                          mode: FileDropMode) -> [UUID] {
        guard !entries.isEmpty else { return [] }
        let folderMode = Self.folderMode(of: mode)
        // One snapshot of the display lanes: those the user was looking at when he let go, not the
        // ones after the first additions.
        let snapshot = laneEntries
        let slots = Self.fileDropLayout(durations: entries.map { $0.duration(mode: folderMode) },
                                        mode: mode, baseLane: baseLane, baseStart: baseStart)
        // A group of a few hundred clips is a lot of engine work: held as ONE edit, so that a
        // playing transport rebuilds its graph once at the end and not at every clip.
        engine?.beginPlaybackEdit()
        defer { engine?.endPlaybackEdit() }

        // A SINGLE display → base round trip, on the first item's lane; the following ones are
        // derived in the coordinates of the container it landed in (@see the drop handler's note on
        // `baseLaneForDisplay`, which is not injective).
        var containerID: UUID? = nil
        var firstBaseLane = 0
        var placed: [UUID] = []
        for (slot, entry) in zip(slots, entries) {
            var obj: SoundObject
            switch entry {
            case .file(let f):
                obj = Self.clipObject(for: f, start: slot.startTime, lane: slot.lane)
            case .folder(let node):
                guard let plan = FolderImport.plan(node, start: slot.startTime, lane: slot.lane,
                                                   mode: folderMode) else { continue }
                obj = Self.groupObject(for: plan)
            }
            if placed.isEmpty {
                obj = placeClip(obj, snapshot: snapshot)
                containerID   = parentGroup(for: obj.id)?.id
                firstBaseLane = obj.lane
            } else {
                obj.lane = firstBaseLane + (slot.lane - slots[0].lane)
                if let containerID {
                    addChild(obj, toGroupID: containerID)
                } else {
                    add(obj)
                }
            }
            resolveOverlaps(for: obj.id)
            placed.append(obj.id)
        }
        return placed
    }

    /// Tells the user what a dropped folder could not give: refused (no audio, too many files) and
    /// sub-folders left out for sitting too deep. Silent when all went well. (The command never
    /// comes here: it answers with the same facts in its result.)
    func reportFolderImportIssues(_ load: DropLoad) {
        if let first = load.refusals.first {
            switch first.failure {
            case .tooManyFiles:
                notify(L("import.folder.tooMany.title"),
                       L("import.folder.tooMany.info", first.name, FolderImport.maxFiles))
            case .noAudio, .notAFolder:
                notify(L("import.folder.noAudio.title"), L("import.folder.noAudio.info", first.name))
            }
        }
        if load.omittedDeepFolders > 0 {
            notify(L("import.folder.deep.title"),
                   L("import.folder.deep.info", load.omittedDeepFolders, FolderImport.maxDepth))
        }
    }

    // MARK: The hover's measure

    /// What the hover learns about one hovered URL: a file's length, or a folder's shape.
    struct FolderPreviewMeasure: Sendable {
        var duration: Double?
        /// A folder's span laid out end to end (its `duration` is the stacked one).
        var sequentialDuration: Double?
        var fileCount: Int?
    }

    /// A folder is READ (listings only) to count its files; it is MEASURED too — every length — only
    /// when it is small enough to be confirmed-free (`FolderImport.confirmThreshold`): hovering a
    /// whole sample library must not open thousands of files. Past that the rectangle keeps the
    /// waiting width and says only how many files it holds.
    nonisolated static func measureForPreview(_ url: URL) async -> FolderPreviewMeasure {
        guard isDirectoryURL(url) else { return FolderPreviewMeasure(duration: await readAudioDuration(url)) }
        let scan = await scanFolder(url)
        guard let root = scan.root else { return FolderPreviewMeasure(fileCount: 0) }
        let count = root.fileCount
        guard count <= FolderImport.confirmThreshold else { return FolderPreviewMeasure(fileCount: count) }
        let measured = FolderImport.filling(root, with: await measureFiles(FolderImport.fileURLs(of: root)))
        return FolderPreviewMeasure(duration: FolderImport.duration(of: measured, mode: .stacked),
                                    sequentialDuration: FolderImport.duration(of: measured, mode: .sequential),
                                    fileCount: count)
    }

    // MARK: Reporting a placed tree (the command's answer)

    /// The tree of ids of what was laid down, read back from the model AFTER placement (so a
    /// `resolveOverlaps` that trimmed something shows in it).
    func placedTree(of id: UUID) -> JSONValue {
        guard let obj = find(id: id) else { return .null }
        var out: [String: JSONValue] = [
            "id": .string(obj.id.uuidString),
            "name": .string(obj.displayName),
            "lane": .int(obj.lane),
            "start": .number(obj.startTime),
            "duration": .number(obj.duration),
        ]
        switch obj.kind {
        case .group(let children, let isExpanded):
            out["kind"] = .string("group")
            out["expanded"] = .bool(isExpanded)
            out["children"] = .array(children.sorted { ($0.lane, $0.startTime) < ($1.lane, $1.startTime) }
                                        .map { placedTree(of: $0.id) })
        case .clip(let path, _, _, _, _):
            out["kind"] = .string("clip")
            out["path"] = .string(path)
        default:
            out["kind"] = .string("other")
        }
        return .object(out)
    }
}

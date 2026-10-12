import Foundation

// MARK: - Importing a folder as a group, hierarchy kept
//
// A folder dropped on the timeline (or handed to `object.import_folder`) becomes ONE collapsed
// group named after it, holding one lane per audio file and one lane per sub-folder — each
// sub-folder being a collapsed group in its turn, to the depth the disk has.
//
// This file is the half of that with NO model, view, engine or AVFoundation behind it, which is
// the reason it can be compiled and asserted alone (`tools/test_folder_import.swift`), like
// `SendColumns` / `LaneCompaction` / `ComposedName`:
//
//   • `scan`  — turns a folder listing into a `Node` tree: audio files only (by extension), hidden
//               entries and packages (a `.app`, a `.logicx`…) ignored, symlinked folders not
//               followed (a loop), folders with no audio below pruned, everything sorted the way the
//               Finder sorts (`localizedStandardCompare`: "take 2" before "take 10"), and the two
//               hard bounds — 8 levels, 2000 files — applied. The LISTING is injected, so the rules
//               are tested against a fake disk and the real one is a separate, thin function.
//   • `plan`  — turns a `Node` tree (the files' durations now known) into a `PlannedGroup` tree:
//               every start, lane and duration, ready for the app to turn into `SoundObject`s.
//
// **Why the output is a plan and not a `SoundObject`.** `SoundObject` drags half the model behind it
// (plugins, sends, automation, markers…); a unit that wants to be compiled alone cannot name it. The
// conversion — one `.clip` or one `.group` per plan entry — is a dozen lines at the single place
// that needs it (`EditViewModel+FolderImport`).
//
// **Layout, the same two modes as a multiple drop** (`EditViewModel.fileDropLayout`):
//   • stacked (default) — everything starts together, one lane per file and per sub-folder;
//   • sequential (⌘)    — one lane, end to end in the listed order.
// A sub-folder is laid out by the same rule INSIDE itself, and counts as one entry (its duration is
// the union of what it holds) in its parent's layout.
//
// **A group's bounds are the UNION of its children's, never an "infinite" extent.** A container
// with an unbounded window is processed by the engine at every block (the CombiningNode walks it in
// 8 s slices): ~20 of them stutter. So `start` is the earliest child start and `duration` runs to
// the latest child end — computed here, once, from what is actually inside.
//
// Order inside a folder: the audio files first, then the sub-folders, each sorted by name.

nonisolated enum FolderImport {

    // MARK: Bounds

    /// Levels below the dropped folder that are read (the dropped folder itself is level 0). Deeper
    /// folders are omitted and reported (`ScanResult.omittedDeepFolders`).
    static let maxDepth = 8
    /// Audio files one import may hold. Over it the import is refused outright (`.tooManyFiles`).
    static let maxFiles = 2000
    /// Above this many files the hand is asked to confirm (the app's job; the API never asks).
    static let confirmThreshold = 200

    // MARK: Tree

    struct FileEntry: Equatable, Sendable {
        var url: URL
        /// Seconds. Unknown until the durations have been read: `plan` takes them from here, so the
        /// loader fills this in between `scan` and `plan`.
        var duration: Double
        var size: Int64?

        init(url: URL, duration: Double = 0, size: Int64? = nil) {
            self.url = url
            self.duration = duration
            self.size = size
        }

        /// The display name: the file's name without its extension — what a clip dropped on its own
        /// is called.
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    struct Node: Equatable, Sendable {
        var name: String
        var files: [FileEntry]
        var subfolders: [Node]

        init(name: String, files: [FileEntry] = [], subfolders: [Node] = []) {
            self.name = name
            self.files = files
            self.subfolders = subfolders
        }

        /// Audio files in this folder and below.
        var fileCount: Int { files.count + subfolders.reduce(0) { $0 + $1.fileCount } }
        var isEmpty: Bool { files.isEmpty && subfolders.isEmpty }
    }

    // MARK: Scanning

    /// One entry of a folder listing, as the injected lister reports it.
    struct DirEntry: Sendable {
        var url: URL
        var isDirectory: Bool
        var isHidden: Bool
        /// A bundle the Finder shows as one file (`.app`, `.logicx`, `.band`…).
        var isPackage: Bool
        var isSymbolicLink: Bool

        init(url: URL, isDirectory: Bool, isHidden: Bool = false,
             isPackage: Bool = false, isSymbolicLink: Bool = false) {
            self.url = url
            self.isDirectory = isDirectory
            self.isHidden = isHidden
            self.isPackage = isPackage
            self.isSymbolicLink = isSymbolicLink
        }
    }

    enum Failure: Equatable, Sendable {
        /// The dropped URL is not a readable folder.
        case notAFolder
        /// No audio file anywhere below: nothing to create.
        case noAudio
        /// More than `maxFiles` audio files (the count found before giving up is attached).
        case tooManyFiles(Int)
    }

    struct ScanResult: Sendable {
        var root: Node?
        var failure: Failure?
        /// Sub-folders holding audio that were left out because they sit deeper than `maxDepth`.
        var omittedDeepFolders: Int = 0
        var fileCount: Int { root?.fileCount ?? 0 }
    }

    /// Reads the folder `root` through `list` (one level at a time, so the rules are testable) and
    /// returns the pruned, sorted tree. `isAudio` receives a lowercased extension.
    static func scan(root: URL,
                     list: (URL) -> [DirEntry]?,
                     isAudio: (String) -> Bool) -> ScanResult {
        guard list(root) != nil else { return ScanResult(root: nil, failure: .notAFolder) }
        var count = 0
        var omitted = 0
        var overflow = false

        func read(_ folder: URL, depth: Int) -> Node? {
            guard let entries = list(folder) else { return nil }
            var node = Node(name: folder.lastPathComponent)
            var files: [DirEntry] = []
            var folders: [DirEntry] = []
            for e in entries where !e.isHidden {
                if e.isDirectory {
                    // A package is a file as far as the Finder is concerned; a symlinked folder is
                    // not followed (a link back up would loop, and there is no way to tell here).
                    if e.isPackage || e.isSymbolicLink { continue }
                    folders.append(e)
                } else if isAudio(e.url.pathExtension.lowercased()) {
                    files.append(e)
                }
            }
            for e in files.sorted(by: byName) {
                if overflow { break }
                count += 1
                if count > maxFiles { overflow = true; break }
                node.files.append(FileEntry(url: e.url))
            }
            for e in folders.sorted(by: byName) {
                if overflow { break }
                if depth >= maxDepth {
                    // Too deep to be read: counted if it would have held audio, so that the caller
                    // can say something was left out. (Only its own level is probed — a deeper
                    // chain below it is one omission, not many.)
                    if holdsAudio(e.url, list: list, isAudio: isAudio, budget: 4000) { omitted += 1 }
                    continue
                }
                if let child = read(e.url, depth: depth + 1), !child.isEmpty {
                    node.subfolders.append(child)
                }
            }
            return node
        }

        guard let tree = read(root, depth: 0) else {
            return ScanResult(root: nil, failure: .notAFolder)
        }
        if overflow { return ScanResult(root: nil, failure: .tooManyFiles(count)) }
        if tree.isEmpty {
            return ScanResult(root: nil, failure: .noAudio, omittedDeepFolders: omitted)
        }
        return ScanResult(root: tree, failure: nil, omittedDeepFolders: omitted)
    }

    private static func byName(_ a: DirEntry, _ b: DirEntry) -> Bool {
        let order = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
        if order != .orderedSame { return order == .orderedAscending }
        // Two names the comparison cannot tell apart (case, Unicode form): the path settles it, so the
        // order never depends on what the disk happened to list first.
        return a.url.path < b.url.path
    }

    /// True if any audio file lives at or below `folder` — used only to decide whether a folder cut
    /// off by the depth bound is worth mentioning. Bounded by `budget` listings.
    private static func holdsAudio(_ folder: URL, list: (URL) -> [DirEntry]?,
                                   isAudio: (String) -> Bool, budget: Int) -> Bool {
        var remaining = budget
        func walk(_ f: URL) -> Bool {
            guard remaining > 0, let entries = list(f) else { return false }
            remaining -= 1
            for e in entries where !e.isHidden {
                if e.isDirectory {
                    if e.isPackage || e.isSymbolicLink { continue }
                    if walk(e.url) { return true }
                } else if isAudio(e.url.pathExtension.lowercased()) {
                    return true
                }
            }
            return false
        }
        return walk(folder)
    }

    /// The real disk's lister. `nil` when the URL is not a readable folder.
    static func diskListing(_ folder: URL) -> [DirEntry]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isPackageKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: []) else { return nil }
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            return DirEntry(url: url,
                            isDirectory: v?.isDirectory ?? false,
                            // `isHidden` covers the flag; the leading dot covers files the Finder
                            // flags no differently (`.DS_Store`, `._foo` AppleDouble companions).
                            isHidden: (v?.isHidden ?? false) || name.hasPrefix("."),
                            isPackage: v?.isPackage ?? false,
                            isSymbolicLink: v?.isSymbolicLink ?? false)
        }
    }

    // MARK: Measuring

    /// Every audio file of the tree, in the order `plan` lays them out (a folder's files, then its
    /// sub-folders, depth first) — the order `filling(_:with:)` hands the measures back in.
    static func fileURLs(of node: Node) -> [URL] {
        node.files.map(\.url) + node.subfolders.flatMap { fileURLs(of: $0) }
    }

    /// The same tree with each file's duration and size filled in from `measures`, which follows
    /// `fileURLs(of:)`'s order (a missing measure leaves the entry untouched).
    static func filling(_ node: Node, with measures: [(duration: Double, size: Int64?)]) -> Node {
        var cursor = 0
        func fill(_ n: Node) -> Node {
            var out = n
            for i in out.files.indices {
                if cursor < measures.count {
                    out.files[i].duration = measures[cursor].duration
                    out.files[i].size = measures[cursor].size
                }
                cursor += 1
            }
            out.subfolders = out.subfolders.map { fill($0) }
            return out
        }
        return fill(node)
    }

    // MARK: Layout

    enum Mode: Equatable, Sendable {
        /// Same start, one lane per entry.
        case stacked
        /// One lane, end to end.
        case sequential
    }

    struct PlacedFile: Equatable, Sendable {
        var entry: FileEntry
        var start: Double
        /// Lane RELATIVE to the group that holds it.
        var lane: Int
    }

    indirect enum Item: Equatable, Sendable {
        case file(PlacedFile)
        case group(PlannedGroup)

        var lane: Int {
            switch self {
            case .file(let f):  return f.lane
            case .group(let g): return g.lane
            }
        }
        var start: Double {
            switch self {
            case .file(let f):  return f.start
            case .group(let g): return g.start
            }
        }
        var end: Double {
            switch self {
            case .file(let f):  return f.start + f.entry.duration
            case .group(let g): return g.start + g.duration
            }
        }
    }

    struct PlannedGroup: Equatable, Sendable {
        var name: String
        /// Absolute seconds: the earliest start among the children.
        var start: Double
        /// Up to the latest child end. Never infinite, never zero while a child has a length.
        var duration: Double
        /// Relative to the group that holds this one (the dropped folder's lane is the caller's).
        var lane: Int
        var items: [Item]

        /// The same group, its start moved to `newStart` (every descendant shifted by the same amount)
        /// and put on `newLane`.
        func moved(to newStart: Double, lane newLane: Int) -> PlannedGroup {
            let delta = newStart - start
            var g = self
            g.start = newStart
            g.lane = newLane
            g.items = items.map { item in
                switch item {
                case .file(var f):
                    f.start += delta
                    return .file(f)
                case .group(let sub):
                    return .group(sub.moved(to: sub.start + delta, lane: sub.lane))
                }
            }
            return g
        }

        /// How many lanes the children use (`max lane + 1`).
        var laneCount: Int { (items.map(\.lane).max() ?? -1) + 1 }
        var fileCount: Int {
            items.reduce(0) { n, item in
                switch item {
                case .file:         return n + 1
                case .group(let g): return n + g.fileCount
                }
            }
        }
        var groupCount: Int {
            items.reduce(1) { n, item in
                if case .group(let g) = item { return n + g.groupCount }
                return n
            }
        }
    }

    /// The group a folder becomes, starting at `start` on `lane`. Every duration must already be in
    /// `Node.files[i].duration`. A folder with no audio at all plans to nil (it is not created).
    static func plan(_ node: Node, start: Double, lane: Int, mode: Mode) -> PlannedGroup? {
        // Entries in the order they are listed: files first, then sub-folders. A sub-folder is planned
        // ONCE, at 0, and then translated to where its place is: its duration (all the layout needs
        // of it) does not depend on where it starts, and planning it twice per level would cost 2^depth.
        enum Entry {
            case file(FileEntry)
            case folder(PlannedGroup)
        }
        var entries: [Entry] = node.files.map { .file($0) }
        for sub in node.subfolders {
            if let measured = plan(sub, start: 0, lane: 0, mode: mode) { entries.append(.folder(measured)) }
        }
        guard !entries.isEmpty else { return nil }

        var items: [Item] = []
        var cursor = start
        for (index, entry) in entries.enumerated() {
            let entryStart = mode == .stacked ? start : cursor
            let entryLane  = mode == .stacked ? index : 0
            switch entry {
            case .file(let f):
                items.append(.file(PlacedFile(entry: f, start: entryStart, lane: entryLane)))
                cursor += f.duration
            case .folder(let g):
                items.append(.group(g.moved(to: entryStart, lane: entryLane)))
                cursor += g.duration
            }
        }
        let lo = items.map(\.start).min() ?? start
        let hi = items.map(\.end).max() ?? start
        return PlannedGroup(name: node.name, start: lo, duration: max(0, hi - lo), lane: lane, items: items)
    }

    /// The span of what a folder drop will cover, for the layout of a drop that mixes files and
    /// folders (a folder takes one lane and this much time, like a file of the same length).
    static func duration(of node: Node, mode: Mode) -> Double {
        plan(node, start: 0, lane: 0, mode: mode)?.duration ?? 0
    }
}

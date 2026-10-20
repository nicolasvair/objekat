import Foundation

// MARK: - Project file usage — "which files of the project folder does anything still read?"
//
// The pure half of the disk-space gauge and of the clean-up of unused files (@see
// `EditViewModel+DiskUsage`). It touches NO disk and NO model: every I/O is INJECTED (the sidecar
// reader of `closure`, the file listing of `universe`), and the model is reduced to `Ref`, a
// three-field tree (an instance's definition id, a clip's path, children). So the whole thing
// compiles alone and is asserted with no screen (@see tools/test_project_file_usage.swift), and a
// background task can run it on data it was HANDED, which is the only safe way to read the disk
// off the main thread in a target whose default isolation is the main actor.
//
// THE MODEL OF A PROJECT FOLDER. Every version file (`*.objekat`, or the legacy `*.json`) of a
// folder shares `samples/` and `waveforms/`. What lives there:
//   • `samples/consolidate/<name>_<def8>[_vN].wav` (`.flac` once the project has been archived — @see
//     `EditViewModel+FlacArchive`) + its sidecar `…_objectstate.json` — a
//     consolidated object's baked wave. EVERY re-bake writes a `_v(N+1)` and none ever deletes the
//     old one: those are the orphans this exists for;
//   • `samples/objects/` — the legacy place of the same files, read for ever, never written;
//   • `samples/sources/` — the sources a "Save a copy" capsule embeds;
//   • `waveforms/<basename>.wfc` — the display caches (regenerable, named after the source file).
// A normal clip points at an ABSOLUTE external path: this unit never lists it, so it can never
// propose to delete it (the universe below is the whole of what may ever be offered).
//
// "USED" is a TRANSITIVE closure: the items name instances (`consolidateID`), an instance names a
// definition, the definition's wave is used and so is its sidecar, and the sidecar holds the
// sub-tree that was baked — clips (sources) and other instances (nested consolidated objects),
// which the closure goes on through. @see `closure`.

/// Which files a clean-up may offer (@see `ProjectFileUsage.Report.cleanable`).
nonisolated enum DiskCleanScope: String, Sendable {
    /// EVERYTHING this session does not read — even what another version of the folder still
    /// reads (those are listed with the versions that read them, and never ticked by default).
    case session
    /// Only what NO version of the folder reads — which needs every other version to be readable.
    case folder
}

nonisolated enum ProjectFileUsage {

    // MARK: - What the model is reduced to

    /// One node of an object tree, as far as FILES go. A group is `children`; a clip is
    /// `filePath`; an instance of a consolidated object is `consolidateID` (+ the `filePath` of
    /// the wave it currently plays).
    struct Ref: Equatable, Sendable {
        var consolidateID: UUID?
        var filePath: String?
        var children: [Ref]

        init(consolidateID: UUID? = nil, filePath: String? = nil, children: [Ref] = []) {
            self.consolidateID = consolidateID
            self.filePath = filePath
            self.children = children
        }
    }

    /// What a definition contributes: its id and the FILE NAME of its current wave.
    struct DefInfo: Equatable, Sendable {
        var id: UUID
        var wave: String

        init(id: UUID, wave: String) {
            self.id = id
            self.wave = wave
        }
    }

    // MARK: - The transitive closure

    enum Problem: Equatable, Sendable {
        /// An instance names a definition the registry does not hold.
        case unknownDefinition(UUID)
        /// A reachable definition whose sidecar could not be read (absent, unreadable).
        case sidecarUnavailable(UUID)
    }

    struct Closure: Equatable, Sendable {
        /// Every definition reached, in the order met (also those the registry does not hold).
        var visitedDefinitions: [UUID] = []
        /// The wave file names of the registered definitions reached.
        var waves: Set<String> = []
        /// The `filePath` of every clip that is NOT an instance — the real sources, those of the
        /// items AND those inside the sidecars reached.
        var sourcePaths: Set<String> = []
        /// The `filePath` of every instance (the wave it currently plays).
        var instancePaths: Set<String> = []
        var problems: [Problem] = []
        /// True when a reachable sidecar could not be read: what it nests is then UNKNOWN, and
        /// `usage` answers by treating every definition of the registry as reached.
        var uncertain: Bool { problems.contains { if case .sidecarUnavailable = $0 { return true } else { return false } } }
    }

    /// Everything the `items` read, going through the definitions' sidecars.
    ///
    /// `readSidecar` is the injected I/O: it returns the sub-tree a definition was baked from, or
    /// nil if it cannot be had. An instance reads the BAKED wave, so its own sub-tree is not
    /// walked — the recursion goes through the definition (and its sidecar), exactly as "Save a
    /// copy" always did.
    static func closure(items: [Ref], defs: [UUID: DefInfo],
                        readSidecar: (DefInfo) -> Ref?) -> Closure {
        var result = Closure()
        var seen = Set<UUID>()
        var queue: [UUID] = []

        // `inSidecar`: the ref comes from a definition's content, not from the session. An instance
        // there names the wave its definition had WHEN THE CONTENT WAS BAKED, and sidecars are never
        // rewritten — a re-bake or a FLAC archive of the inner definition leaves that path stale. It
        // is not read: opening the content re-aims the instance onto its definition's CURRENT wave,
        // which the definition itself marks (`waves`). So such a path counts only when the definition
        // is unknown here (the path is then the only clue there is). Counting it always kept the
        // inner WAV "used" for ever after the archive (bug of 20 October 2026).
        func walk(_ ref: Ref, inSidecar: Bool) {
            if let id = ref.consolidateID {
                if let path = ref.filePath, !inSidecar || defs[id] == nil { result.instancePaths.insert(path) }
                if seen.insert(id).inserted {
                    queue.append(id)
                    result.visitedDefinitions.append(id)
                }
                return
            }
            if let path = ref.filePath { result.sourcePaths.insert(path) }
            ref.children.forEach { walk($0, inSidecar: inSidecar) }
        }

        items.forEach { walk($0, inSidecar: false) }
        var i = 0
        while i < queue.count {
            let id = queue[i]
            i += 1
            guard let def = defs[id] else {
                result.problems.append(.unknownDefinition(id))
                continue
            }
            result.waves.insert(def.wave)
            if let sub = readSidecar(def) {
                walk(sub, inSidecar: true)
            } else {
                result.problems.append(.sidecarUnavailable(id))
            }
        }
        return result
    }

    // MARK: - From a closure to "which files of the folder"

    /// The folder-relative paths and the base names a closure reads. Two vocabularies because the
    /// two kinds of file are named two ways: a wave or a source by its place (`samples/…`), a
    /// `.wfc` cache by the name of the file it caches (so it follows an EXTERNAL source too).
    struct Usage: Equatable, Sendable {
        var rel: Set<String> = []
        var names: Set<String> = []

        init(rel: Set<String> = [], names: Set<String> = []) {
            self.rel = rel
            self.names = names
        }

        mutating func formUnion(_ other: Usage) {
            rel.formUnion(other.rel)
            names.formUnion(other.names)
        }
    }

    static let consolidateRel = "samples/consolidate"
    static let legacyRel = "samples/objects"
    static let sourcesRel = "samples/sources"
    static let waveformsRel = "waveforms"
    static let sidecarSuffix = "_objectstate.json"

    /// `x_v2.wav` → `x_v2_objectstate.json` (the sidecar sits next to its wave, named after it).
    static func sidecarName(forWave wave: String) -> String {
        "\((wave as NSString).deletingPathExtension)\(sidecarSuffix)"
    }

    /// What `closure` reads, in the folder's terms.
    ///
    /// A wave is marked in BOTH `consolidate/` and `objects/` (the app reads either, and a project
    /// duplicated in the Finder can name the other one — @see `ProjectPaths.resolved`): marking
    /// only the place the wave was found would let the twin be offered for deletion.
    /// When a sidecar was unreadable (`uncertain`), every definition of `defs` is marked: what
    /// that sidecar nests is unknown, and "unused" must never rest on a guess.
    static func usage(of closure: Closure, defs: [UUID: DefInfo], folder: URL) -> Usage {
        var u = Usage()
        var waves = closure.waves
        if closure.uncertain { waves.formUnion(defs.values.map(\.wave)) }
        for wave in waves {
            u.names.insert(wave)
            for dir in [consolidateRel, legacyRel] {
                u.rel.insert("\(dir)/\(wave)")
                u.rel.insert("\(dir)/\(sidecarName(forWave: wave))")
            }
        }
        for path in closure.sourcePaths.union(closure.instancePaths) where !path.isEmpty {
            u.names.insert((path as NSString).lastPathComponent)
            u.rel.formUnion(relativeMarks(of: path, folder: folder))
        }
        return u
    }

    /// `/private/tmp/p` and `/tmp/p` are one folder on macOS; so are `/private/var` and `/var`.
    /// Pure (no symbolic link is resolved here), hence only these fixed aliases.
    static func canonical(_ path: String) -> String {
        for dir in ["tmp", "var", "etc"] where path == "/private/\(dir)" || path.hasPrefix("/private/\(dir)/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private static func components(of path: String) -> [String] {
        var out: [String] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(String(c))
        }
        return out
    }

    /// The folder-relative spellings under which a clip path can name a file of the folder:
    ///   • a relative path, or an absolute one inside the folder → the path itself, relative;
    ///   • any path going through `samples/<consolidate|objects|sources>/<file>` → that place
    ///     (the loader redirects such a path to THIS folder's file of the same name when it has
    ///     one), and for the two wave folders the twin place too.
    /// A path that names nothing of the folder (an external file) gives an empty set.
    static func relativeMarks(of path: String, folder: URL) -> Set<String> {
        var marks = Set<String>()
        let folderComps = components(of: canonical(folder.standardizedFileURL.path))
        let comps: [String]
        let isAbsolute = path.hasPrefix("/")
        if isAbsolute {
            let all = components(of: canonical(path))
            if all.count > folderComps.count, Array(all.prefix(folderComps.count)) == folderComps {
                comps = Array(all.dropFirst(folderComps.count))
                marks.insert(comps.joined(separator: "/"))
            } else {
                comps = all
            }
        } else {
            comps = components(of: path)
            if !comps.isEmpty { marks.insert(comps.joined(separator: "/")) }
        }
        // The last `samples/<leaf>/<file>` of the path, whatever precedes it.
        if comps.count >= 3 {
            for i in stride(from: comps.count - 3, through: 0, by: -1) where comps[i] == "samples" {
                guard i + 3 == comps.count else { continue }
                let leaf = comps[i + 1]
                guard ["consolidate", "objects", "sources"].contains(leaf) else { continue }
                let file = comps[i + 2]
                marks.insert("samples/\(leaf)/\(file)")
                if leaf == "consolidate" { marks.insert("samples/objects/\(file)") }
                if leaf == "objects" { marks.insert("samples/consolidate/\(file)") }
                break
            }
        }
        return marks
    }

    // MARK: - The universe: the only files that may ever be offered

    /// One regular file found on disk, relative to the project folder.
    struct Listed: Equatable, Sendable {
        var rel: String
        var size: Int64

        init(rel: String, size: Int64) {
            self.rel = rel
            self.size = size
        }
    }

    enum Kind: String, Equatable, Sendable {
        /// A wave of `samples/consolidate/` (+ its sidecar).
        case consolidatedWave
        /// A wave of the legacy `samples/objects/` (+ its sidecar).
        case legacyWave
        /// A source a capsule embedded, in `samples/sources/`.
        case embeddedSource
        /// A `waveforms/*.wfc` cache with no file of the universe to follow.
        case waveformCache
        /// A sidecar whose wave is gone.
        case strayFile
        /// A WAV elsewhere in the project folder (outside the folders above) with a FLAC of the same
        /// name beside it: the original the FLAC archive left behind (@see `EditViewModel+FlacArchive`,
        /// which converts any WAV of the project folder the project reads). Without this kind it was
        /// never offered, however unread (bug of 20 October 2026).
        case archivedOriginal
    }

    /// A unit that is kept or trashed AS ONE: a wave with its sidecar and its `.wfc` cache.
    struct Candidate: Equatable, Sendable, Identifiable {
        /// The primary file's folder-relative path — stable, and the key everything else uses.
        let id: String
        let kind: Kind
        /// The primary file's name.
        let name: String
        /// The sub-folder it lives in (`samples/consolidate`, …).
        let folder: String
        /// Every file of the unit, folder-relative, the primary one first.
        let files: [String]
        /// The unit's weight in bytes.
        let size: Int64
    }

    /// The candidates in `listing` — and only them. Everything else is OUT of the universe and can
    /// never be offered: files at the root of `samples/`, in deeper sub-folders, anything of the
    /// project folder that is not `samples/{consolidate,objects,sources}/` or `waveforms/*.wfc`,
    /// dot files (`.DS_Store`) — with ONE exception: a `.wav` anywhere else in the folder that has a
    /// `.flac` of the same name beside it (`archivedOriginal`, what the FLAC archive leaves behind).
    static func universe(listing: [Listed]) -> [Candidate] {
        var byFolder: [String: [String: Int64]] = [:]    // folder → file name → size
        for item in listing {
            let comps = item.rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let name = comps.last, !name.hasPrefix(".") else { continue }
            let folder = comps.dropLast().joined(separator: "/")
            switch folder {
            case consolidateRel, legacyRel, sourcesRel: break
            case waveformsRel: guard name.hasSuffix(".wfc") else { continue }
            default: continue
            }
            byFolder[folder, default: [:]][name] = item.size
        }
        // The WAVs of the rest of the folder that have a FLAC twin (archived originals).
        var archived: [(rel: String, name: String, folder: String, size: Int64)] = []
        do {
            var byDir: [String: [String: Int64]] = [:]
            for item in listing {
                let comps = item.rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                guard let name = comps.last, !name.hasPrefix("."),
                      !comps.dropLast().contains(where: { $0.hasPrefix(".") }) else { continue }
                let folder = comps.dropLast().joined(separator: "/")
                if [consolidateRel, legacyRel, sourcesRel, waveformsRel].contains(folder) { continue }
                byDir[folder, default: [:]][name] = item.size
            }
            for (folder, files) in byDir {
                let flacBases = Set(files.keys.filter { ($0 as NSString).pathExtension.lowercased() == "flac" }
                                        .map { ($0 as NSString).deletingPathExtension })
                for (name, size) in files where (name as NSString).pathExtension.lowercased() == "wav"
                    && flacBases.contains((name as NSString).deletingPathExtension) {
                    archived.append((folder.isEmpty ? name : "\(folder)/\(name)", name, folder, size))
                }
            }
            archived.sort { $0.rel < $1.rel }
        }
        var wfc = byFolder[waveformsRel] ?? [:]
        var out: [Candidate] = []

        func attachedCache(of name: String) -> (rel: String, size: Int64)? {
            guard let size = wfc.removeValue(forKey: "\(name).wfc") else { return nil }
            return ("\(waveformsRel)/\(name).wfc", size)
        }

        for folder in [consolidateRel, legacyRel, sourcesRel] {
            let files = byFolder[folder] ?? [:]
            var sidecars: [String: String] = [:]      // wave base name → sidecar file name
            if folder != sourcesRel {
                for name in files.keys where name.hasSuffix(sidecarSuffix) {
                    sidecars[String(name.dropLast(sidecarSuffix.count))] = name
                }
            }
            var claimed = Set<String>()
            for name in files.keys.sorted() {
                if folder != sourcesRel, name.hasSuffix(sidecarSuffix) { continue }
                var rels = ["\(folder)/\(name)"]
                var size = files[name] ?? 0
                if folder != sourcesRel,
                   let sidecar = sidecars[(name as NSString).deletingPathExtension],
                   !claimed.contains(sidecar) {
                    claimed.insert(sidecar)
                    rels.append("\(folder)/\(sidecar)")
                    size += files[sidecar] ?? 0
                }
                if let cache = attachedCache(of: name) {
                    rels.append(cache.rel)
                    size += cache.size
                }
                let kind: Kind = folder == consolidateRel ? .consolidatedWave
                    : folder == legacyRel ? .legacyWave : .embeddedSource
                out.append(Candidate(id: rels[0], kind: kind, name: name, folder: folder,
                                     files: rels, size: size))
            }
            // A sidecar nobody claimed: its wave is gone.
            for (base, sidecar) in sidecars.sorted(by: { $0.value < $1.value })
            where !claimed.contains(sidecar) {
                _ = base
                let rel = "\(folder)/\(sidecar)"
                out.append(Candidate(id: rel, kind: .strayFile, name: sidecar, folder: folder,
                                     files: [rel], size: files[sidecar] ?? 0))
            }
        }
        for a in archived {
            var rels = [a.rel]
            var size = a.size
            if let cache = attachedCache(of: a.name) {
                rels.append(cache.rel)
                size += cache.size
            }
            out.append(Candidate(id: a.rel, kind: .archivedOriginal, name: a.name, folder: a.folder,
                                 files: rels, size: size))
        }
        for name in wfc.keys.sorted() {
            let rel = "\(waveformsRel)/\(name)"
            out.append(Candidate(id: rel, kind: .waveformCache, name: name, folder: waveformsRel,
                                 files: [rel], size: wfc[name] ?? 0))
        }
        return out
    }

    // MARK: - Classifying

    /// What one OTHER version file of the folder reads.
    struct OtherVersion: Equatable, Sendable {
        var name: String
        var usage: Usage

        init(name: String, usage: Usage) {
            self.name = name
            self.usage = usage
        }
    }

    /// A unit the session does not read but another version of the folder does.
    struct UsedElsewhere: Equatable, Sendable, Identifiable {
        var candidate: Candidate
        /// The readable versions that read it, by name. (A version that could not be read is not
        /// in here: it is reported apart, and nobody can tell what it reads.)
        var usedBy: [String]
        var id: String { candidate.id }
    }

    struct Report: Equatable, Sendable {
        /// Read by the session itself.
        var used: [Candidate] = []
        /// Read by something the session cannot see in its items (the clipboard, an open or parked
        /// tab, an edit or a bake under way, the saved copy of a modified version): never
        /// offered, in any scope.
        var protected: [Candidate] = []
        /// Not read by the session, but by another version of the folder: offered by the
        /// `session` scope (never ticked by default), kept by the `folder` scope.
        var usedElsewhere: [UsedElsewhere] = []
        /// Read by nobody: offered by both scopes, ticked by default.
        var unused: [Candidate] = []

        var usedBytes: Int64 { used.reduce(0) { $0 + $1.size } }
        var protectedBytes: Int64 { protected.reduce(0) { $0 + $1.size } }
        var usedElsewhereBytes: Int64 { usedElsewhere.reduce(0) { $0 + $1.candidate.size } }
        var unusedBytes: Int64 { unused.reduce(0) { $0 + $1.size } }

        /// The versions that read `id` (empty when nothing but the session's own past does).
        func usedBy(_ id: String) -> [String] {
            usedElsewhere.first { $0.candidate.id == id }?.usedBy ?? []
        }

        /// What may be cleaned in `scope`, or nil when the scope cannot answer.
        ///   • `session`: everything THIS session does not read — the pure orphans first, then the
        ///     files another version still reads. An unreadable version does not stand in the way
        ///     (it only means "who reads this" is not fully known).
        ///   • `folder`: only what NO version reads, and nothing at all (nil) while a version of
        ///     the folder cannot be read, since it might read anything.
        /// So `session` is always a superset of `folder`.
        func cleanable(in scope: DiskCleanScope, unreadableVersions: [String]) -> [Candidate]? {
            switch scope {
            case .session: return unused + usedElsewhere.map(\.candidate)
            case .folder: return unreadableVersions.isEmpty ? unused : nil
            }
        }
    }

    /// Whether `usage` reads this unit. A wave, a source or a sidecar is read when its place is
    /// named; a `.wfc` of its own is read when the file it caches is named, WHEREVER that file is.
    /// (A `.wfc` attached to a wave follows its wave: its place is never named, on purpose.)
    static func reads(_ usage: Usage, _ candidate: Candidate) -> Bool {
        switch candidate.kind {
        case .waveformCache:
            return usage.names.contains(String(candidate.name.dropLast(".wfc".count)))
        case .consolidatedWave, .legacyWave, .embeddedSource, .strayFile, .archivedOriginal:
            return candidate.files.contains { usage.rel.contains($0) }
        }
    }

    /// Sorts every candidate into exactly one bucket, in this order of precedence: read by the
    /// session → read by a protected holder → read by another version → read by nobody.
    static func classify(universe: [Candidate], session: Usage, protected: Usage,
                         others: [OtherVersion]) -> Report {
        var report = Report()
        for candidate in universe {
            if reads(session, candidate) { report.used.append(candidate); continue }
            if reads(protected, candidate) { report.protected.append(candidate); continue }
            let holders = others.filter { reads($0.usage, candidate) }.map(\.name)
            if !holders.isEmpty {
                report.usedElsewhere.append(UsedElsewhere(candidate: candidate, usedBy: holders))
            } else {
                report.unused.append(candidate)
            }
        }
        return report
    }

    // MARK: - Reading the version files (light decoding)

    enum DecodeError: Error, Equatable {
        /// Valid JSON that is not a session (no `items`).
        case notASession
    }

    struct SessionRefs: Equatable, Sendable {
        var items: [Ref]
        var defs: [DefInfo]
    }

    /// The `kind` of an object, as far as files go. TOLERANT on purpose: this reads the version
    /// files of OTHER versions of the app, and refusing a kind it does not know would turn an
    /// unfamiliar-but-valid file into "unreadable" for no file-related reason.
    private struct KindRefs: Decodable {
        var filePath: String?
        var children: [RefNode]?

        enum CodingKeys: String, CodingKey { case filePath, children }
        nonisolated init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            filePath = try? c.decodeIfPresent(String.self, forKey: .filePath)
            children = try? c.decodeIfPresent([RefNode].self, forKey: .children)
        }
    }

    private struct RefNode: Decodable {
        var consolidateID: UUID?
        var kind: KindRefs?

        enum CodingKeys: String, CodingKey { case consolidateID = "definitionID", kind }
        nonisolated init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            consolidateID = try? c.decodeIfPresent(UUID.self, forKey: .consolidateID)
            kind = try? c.decodeIfPresent(KindRefs.self, forKey: .kind)
        }

        nonisolated var ref: Ref {
            Ref(consolidateID: consolidateID, filePath: kind?.filePath,
                children: (kind?.children ?? []).map(\.ref))
        }
    }

    private struct DefNode: Decodable {
        var id: UUID
        var wave: String
    }

    private struct SessionNode: Decodable {
        var items: [RefNode]
        var objectDefinitions: [DefNode]?
    }

    /// The files a session JSON reads, without decoding anything else of it (no plugin state, no
    /// automation: a project can weigh megabytes of that).
    /// Throws if the data is not JSON, or is JSON without `items`.
    static func decodeSession(_ data: Data) throws -> SessionRefs {
        let node = try JSONDecoder().decode(SessionNode.self, from: data)
        return SessionRefs(items: node.items.map(\.ref),
                           defs: (node.objectDefinitions ?? []).map { DefInfo(id: $0.id, wave: $0.wave) })
    }

    /// The sub-tree a `*_objectstate.json` sidecar holds.
    static func decodeSidecar(_ data: Data) throws -> Ref {
        try JSONDecoder().decode(RefNode.self, from: data).ref
    }

    enum FileVerdict: Equatable, Sendable {
        /// A JSON object with the marks of a session.
        case session
        /// Valid JSON that is not a session (some other tool's file): ignored.
        case notASession
        /// Not JSON at all (truncated, garbage): it may well be a damaged session, so it is
        /// reported as unreadable rather than ignored.
        case invalid
    }

    static func verdict(of data: Data) -> FileVerdict {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .invalid }
        guard let object = any as? [String: Any] else { return .notASession }
        return object["items"] != nil || object["_readme"] != nil ? .session : .notASession
    }

    /// True if `data` is a JSON OBJECT carrying the marks of a session (`items`, or the `_readme`
    /// notice a session starts with). A `.json` that is some other tool's file (a `package.json`
    /// lying in the folder) is not a session, and must not stand in the way of a clean-up.
    static func looksLikeSession(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return object["items"] != nil || object["_readme"] != nil
    }
}

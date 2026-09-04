import Foundation

// MARK: - Portable paths (a project folder has to be movable)
//
// A `.clip` carries a file path. Two clearly distinct natures:
//   • an EXTERNAL file (sound library, Finder): it lives outside the project folder → an ABSOLUTE
//     path, the only way to find it again, and moving the project does not concern it;
//   • an INTERNAL file (`samples/objects/` for sound-object waves, `samples/sources/`
//     for a capsule's embedded sources): it travels WITH the project → we record a path
//     RELATIVE to the project folder, otherwise moving (or renaming) the folder breaks the link.
//
// The conversion happens at the write/read boundaries — the `.objekat.json` version file
// and the `*_objectstate.json` sidecars — never in memory: the live model, the engine and the
// waveform cache go on handling absolute paths.
//
// The `.wfc` caches have nothing to rewrite: they are named after the file name alone and
// validated on (size, mtime), which a move preserves.
enum ProjectPaths {

    /// The project folder's sub-folders that host audio, in search order.
    private static let audioSubfolders = ["samples/objects", "samples/sources"]

    // MARK: Writing

    /// The path as it gets recorded: relative if the file lives in the project folder,
    /// absolute otherwise (an external file).
    static func portable(_ path: String, projectFolder: URL) -> String {
        guard !path.isEmpty else { return path }
        let base = projectFolder.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        guard full.hasPrefix(prefix) else { return path }
        return String(full.dropFirst(prefix.count))
    }

    // MARK: Reading

    /// The path as it gets used in memory: always absolute.
    ///
    /// - relative ⇒ resolved inside the current project folder (folder moved: the link follows);
    /// - absolute but going through a project audio folder (`samples/objects|sources/…`) ⇒ if THIS
    ///   project has the file at the same relative place, that is the one that counts. This is what
    ///   catches up projects saved before portability, whether they were moved
    ///   (the old path no longer points at anything) or duplicated (the old path still exists,
    ///   but names the OTHER project's wave — the one next door is the right one);
    /// - otherwise ⇒ unchanged (an external source).
    static func resolved(_ path: String, projectFolder: URL) -> String {
        guard !path.isEmpty else { return path }
        if !path.hasPrefix("/") {
            return projectFolder.appendingPathComponent(path).standardizedFileURL.path
        }
        if let suffix = audioSuffix(of: path) {
            let local = projectFolder.appendingPathComponent(suffix).standardizedFileURL
            if FileManager.default.fileExists(atPath: local.path) { return local.path }
        }
        return path
    }

    /// "/old/project/samples/objects/x.wav" → "samples/objects/x.wav". nil if the path goes
    /// through no project audio folder. The LAST occurrence is the one kept (a project filed
    /// inside a folder named `samples` must not skew the cut).
    private static func audioSuffix(of path: String) -> String? {
        let comps = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard comps.count >= 3 else { return nil }
        for i in stride(from: comps.count - 3, through: 0, by: -1) where comps[i] == "samples" {
            let leaf = comps[i + 1]
            guard audioSubfolders.contains("samples/\(leaf)") else { continue }
            return comps[i...].joined(separator: "/")
        }
        return nil
    }

    // MARK: Walking

    /// Applies `transform` to the path of every `.clip` in the sub-tree (recursive over groups).
    static func rewritingClipPaths(_ o: SoundObject,
                                   _ transform: (String) -> String) -> SoundObject {
        var n = o
        switch o.kind {
        case .clip(let fp, let so, let fd, let sr, let rev):
            n.kind = .clip(filePath: transform(fp), sourceOffset: so, fileDuration: fd,
                           speedRatio: sr, isReversed: rev)
        case .group(let children, let isExpanded):
            n.kind = .group(children: children.map { rewritingClipPaths($0, transform) },
                            isExpanded: isExpanded)
        case .aux, .midiClip:
            break
        }
        return n
    }
}

extension EditViewModel {

    // MARK: - Conversions at the edge of the project's I/O

    /// Items ready to be written into a version file laid down in `folder`.
    func portableItems(_ list: [SoundObject], projectFolder folder: URL) -> [SoundObject] {
        list.map { ProjectPaths.rewritingClipPaths($0) { ProjectPaths.portable($0, projectFolder: folder) } }
    }

    /// Items read back from a version file laid down in `folder`, paths made absolute.
    func resolvedItems(_ list: [SoundObject], projectFolder folder: URL) -> [SoundObject] {
        list.map { ProjectPaths.rewritingClipPaths($0) { ProjectPaths.resolved($0, projectFolder: folder) } }
    }

    // MARK: - Sound-object sidecars

    /// Encodes a sound object's editable sub-tree, paths made portable. `folder` is the
    /// PROJECT folder (not `samples/objects/`): the relative-path convention is the same
    /// as in the version file.
    ///
    /// The automation laid on the sub-tree's ROOT is SHARED OUT along the way: what the render
    /// bakes in stays, what belongs to the instance goes — @see
    /// `SoundObject.asObjectDefinition`, which carries the rule. It is applied here because this
    /// is the ONE WAY THROUGH for every sidecar write (creation, closing an edit,
    /// a headless re-bake, saving a copy): a single site to hold, instead of a definition
    /// that would leave carrying an instance's automation as soon as one more write path
    /// was added. Idempotent: re-encoding an already read sidecar removes nothing more.
    func encodedObjectSidecar(_ subtree: SoundObject, projectFolder folder: URL?) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let definition = subtree.asObjectDefinition
        guard let folder else { return try enc.encode(definition) }
        return try enc.encode(ProjectPaths.rewritingClipPaths(definition) {
            ProjectPaths.portable($0, projectFolder: folder)
        })
    }

    /// Decodes a sidecar and makes its paths absolute in the CURRENT project.
    func decodedObjectSidecar(_ data: Data, projectFolder folder: URL?) throws -> SoundObject {
        let subtree = try JSONDecoder().decode(SoundObject.self, from: data)
        guard let folder else { return subtree }
        return ProjectPaths.rewritingClipPaths(subtree) {
            ProjectPaths.resolved($0, projectFolder: folder)
        }
    }
}

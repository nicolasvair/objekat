import Foundation

// MARK: - File-change detection — the pure half
//
// A source file can change under the project's feet: a take re-saved by an audio editor, a bounce
// re-exported over itself. Detecting it costs ONE `stat` per distinct path (size + modification
// time) — never a hash, never a watcher. This unit is the half of the feature that touches no
// model, no engine and no view, so it compiles alone and is asserted with no screen
// (@see tools/test_file_change_detection.swift); the half that acts on the answer is
// `EditViewModel+ChangedFiles`.
//
// The rules it owns, because they are the ones a script or a unit test can get wrong:
//   • the unit is the PATH — N objects on one take are ONE question and, if it changed, ONE reload;
//   • a path with no earlier identity is not "changed", it is UNKNOWN: it is learned (the first
//     scan after an opening), never reloaded on a guess;
//   • a file that has gone is not "changed" either — that is `EditViewModel+MissingFiles`' business,
//     and reloading a ghost would only fail;
//   • what the app writes itself (the project's `samples/consolidate`, `samples/objects`,
//     `samples/sources`) is never scanned: those files change by the app's own hand, and treating
//     them as external edits would rebuild an object under a bake that is still landing.

/// A file's identity as far as this feature needs one: its size, and — when known — its
/// modification time. `mtime == nil` means "only the size was recorded" (the model keeps a size per
/// clip, no time): two identities are then compared on the size alone.
nonisolated struct SourceFileIdentity: Equatable, Sendable {
    var size: Int64
    var mtime: Double?

    /// True if this is not the same file content as `other`, as far as size and time can say.
    /// A time is compared only when BOTH sides carry one.
    func differs(from other: SourceFileIdentity) -> Bool {
        if size != other.size { return true }
        if let a = mtime, let b = other.mtime { return a != b }
        return false
    }
}

nonisolated enum FileChangeDetection {

    /// The identity of the file at `path`, or nil if it cannot be reached. ONE `stat` — the call a
    /// scan makes per distinct path, off the main thread. Follows symlinks (it is the content that
    /// matters). The time keeps its nanoseconds: two saves inside one second are two identities.
    static func identity(ofFileAt path: String) -> SourceFileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return SourceFileIdentity(size: Int64(info.st_size), mtime: mtime)
    }

    /// The identity of each path, nil for one that cannot be reached. Deduplicated by the caller.
    static func identities(ofFilesAt paths: [String]) -> [String: SourceFileIdentity?] {
        var out: [String: SourceFileIdentity?] = [:]
        out.reserveCapacity(paths.count)
        for path in paths { out[path] = identity(ofFileAt: path) }
        return out
    }

    /// True if `path` lies under one of `folders` (the project folders the app writes itself).
    /// Compared on whole path COMPONENTS: `/p/samples/consolidate-old/x.wav` is not under
    /// `/p/samples/consolidate`. Symlinks are not resolved — both sides are paths the app built.
    static func isAppWritten(_ path: String, under folders: [String]) -> Bool {
        for folder in folders where !folder.isEmpty {
            let base = folder.hasSuffix("/") ? folder : folder + "/"
            if path.hasPrefix(base) { return true }
        }
        return false
    }

    /// The distinct paths a scan must ask the disk about: the objects' paths, minus the empty ones
    /// and the app-written ones, in first-seen order (deterministic, which a headless assertion
    /// needs).
    static func scanPaths(objectPaths: [String], appWrittenFolders: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in objectPaths where !path.isEmpty {
            guard seen.insert(path).inserted, !isAppWritten(path, under: appWrittenFolders) else { continue }
            out.append(path)
        }
        return out
    }

    /// THE decision: which paths changed between what was known (`before`) and what the disk says
    /// now (`after`, nil = unreachable). Each path comes out at most once however many objects
    /// name it; order is first-seen. A path is changed only if it has an earlier identity AND is
    /// reachable now AND the two differ — unknown is learned, gone is not this feature's.
    static func changedPaths(objectPaths: [String],
                             before: [String: SourceFileIdentity],
                             after: [String: SourceFileIdentity?]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in objectPaths where !path.isEmpty {
            guard seen.insert(path).inserted,
                  let earlier = before[path],
                  let now = after[path] ?? nil else { continue }
            if now.differs(from: earlier) { out.append(path) }
        }
        return out
    }
}

import Foundation
import AppKit

// MARK: - Missing files (detection)
//
// A clip names a file on disk. That file can go: a drive unplugged, a folder moved, a take
// renamed outside the project. The engine already knows what to do about it — a file it cannot
// open makes `addSoundObject` give up BEFORE the clip is created, so the object exists in the
// model and is a ghost in the engine — but nothing in the app SAID so. This is the half that says
// it, and only that: it detects and remembers, it repairs nothing.
//
// THE TRAP THIS WHOLE FILE IS BUILT AROUND: the predicate is read by the timeline's CANVAS, which
// means potentially once per block per frame, and by the sound list on top of that. A `FileManager`
// call in `isMissing` would put a stat() — a SYNCHRONOUS disk access, and on a network volume a
// disk access that can BLOCK for seconds — inside the drawing pass. So the two are separated for
// good: the disk is read ONLY in `rescanMissingFiles()`, at the doors where the answer can
// actually have changed (opening a project, after a relink, a volume mounting or going away), and
// everything else is a lookup in the `missingPaths` dictionary. Nothing in this file may be given
// a second caller that reads the disk from a view body.
//
// The unit of the dictionary is the PATH and not the object, because that is the unit of the
// repair too: one file gone breaks the N objects that reference it, and putting it back mends all
// N at once. What the user sees is still the OBJECT in red — "this sound does not work" — which is
// why `isMissing` takes an object and resolves it through its path.

/// The volume-mount observers, by view-model. They live in a file-private table rather than as a
/// second stored property on `EditViewModel` for the one reason a Swift extension always gives:
/// an extension cannot carry stored state, and the class's own storage is kept for
/// `missingPaths`, which the whole app reads. Keyed by identity so the tokens can be handed back
/// — an observer left behind would go on rescanning a project that is gone.
@MainActor private var missingFileWatchTokens: [ObjectIdentifier: [NSObjectProtocol]] = [:]

extension EditViewModel {

    /// WHY a file cannot be found. The distinction is not cosmetic: an absent file is an accident
    /// to repair by hand, whereas an unmounted volume repairs itself the moment the drive is
    /// plugged back in — telling someone to go and find a file that is simply on a disk they have
    /// not connected is telling them the wrong thing.
    enum MissingReason: String, Sendable {
        /// The path is reachable and there is nothing there.
        case absent
        /// The path lives on a `/Volumes/<name>` that is not mounted. The file may be perfectly
        /// well where it has always been.
        case volumeOffline
    }

    // MARK: - Reading (no disk, ever)

    /// True if this object's source file could not be found at the last scan.
    ///
    /// A pure dictionary lookup — see the note at the head of this file. Only a `.clip` can be
    /// missing: a group, an aux and a MIDI clip name no file at all, so they are never missing,
    /// whatever their content (for a group's DESCENDANTS, see `containsMissingDescendant`, which
    /// is deliberately a separate question rather than a lie told by this one).
    func isMissing(_ object: SoundObject) -> Bool {
        missingReason(for: object) != nil
    }

    /// Why this object's file could not be found, or nil if it is there (or if the object names
    /// no file). Same rule, same cost, as `isMissing`.
    func missingReason(for object: SoundObject) -> MissingReason? {
        guard case .clip(let path, _, _, _, _) = object.kind, !path.isEmpty else { return nil }
        return missingPaths[path]
    }

    /// True if anything in this object's sub-tree is missing its file. A GROUP must be able to say
    /// that something inside it is broken — a group folded shut hides its own children, and a red
    /// clip nobody can see is a red clip nobody reads — but it must say it AS ITS OWN STATEMENT.
    /// Hence a second function rather than a wider `isMissing`: the two mean different things (the
    /// group's own file is not gone, it has none), they drive different drawings, and a relink
    /// acts on the clips this finds, never on the group.
    ///
    /// Walks the sub-tree and reads the dictionary at the leaves: no disk here either. Depth is
    /// the nesting of the groups, so the recursion is bounded by the project's own structure.
    func containsMissingDescendant(_ object: SoundObject) -> Bool {
        guard case .group(let children, _) = object.kind else { return false }
        for child in children {
            if isMissing(child) { return true }
            if containsMissingDescendant(child) { return true }
        }
        return false
    }

    /// The number of OBJECTS whose file is missing — not the number of paths. It is the figure a
    /// human counts ("four sounds are broken"), where `missingPathsSorted` carries the figure a
    /// repair works in.
    var missingFileCount: Int {
        guard !missingPaths.isEmpty else { return 0 }   // the common case: nothing to walk
        return allClips.reduce(into: 0) { total, clip in
            if missingReason(for: clip) != nil { total += 1 }
        }
    }

    /// The missing paths, each with its reason and the number of objects that reference it. THE
    /// PATH IS THE UNIT OF THE REPAIR: relinking one of these mends every object in its `count`,
    /// in one undo step. Sorted by path with a plain ordinal comparison — deterministic, unlike a
    /// localised one, which is what a headless assertion needs.
    var missingPathsSorted: [(path: String, reason: MissingReason, count: Int)] {
        guard !missingPaths.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for clip in allClips {
            guard case .clip(let path, _, _, _, _) = clip.kind,
                  missingPaths[path] != nil else { continue }
            counts[path, default: 0] += 1
        }
        return missingPaths.keys.sorted().map { path in
            (path: path, reason: missingPaths[path] ?? .absent, count: counts[path] ?? 0)
        }
    }

    // MARK: - Scanning (the ONLY place that reads the disk)

    /// Rebuilds `missingPaths` by asking the disk about every distinct path the project's clips
    /// name. THE one door onto the file system in this file — call it at the moments where the
    /// answer can have changed, and nowhere near a view body: opening a project, after a relink,
    /// on a volume mounting or going away (@see `armMissingFileWatch`).
    ///
    /// Deduplicated by path before the stat: N objects reading one file cost ONE question, which
    /// matters for a project built out of a handful of long takes.
    ///
    /// The result is written back ONLY if it differs. `missingPaths` is observed — the canvas
    /// redraws on it — so reassigning an identical dictionary on every mount notification would
    /// invalidate the whole timeline for nothing.
    func rescanMissingFiles() {
        var found: [String: MissingReason] = [:]
        var asked = Set<String>()
        // `allClips` flattens recursively and never yields the groups themselves, so a clip
        // nested three groups deep, in groups folded shut, is reached exactly like a top-level
        // one — which is the whole requirement here. (@see EditViewModel.allClips)
        for clip in allClips {
            guard case .clip(let path, _, _, _, _) = clip.kind, !path.isEmpty else { continue }
            guard asked.insert(path).inserted else { continue }
            if let reason = Self.missingReason(ofFileAt: path) { found[path] = reason }
        }
        if found != missingPaths { missingPaths = found }
    }

    /// The disk verdict for one path. `nil` = the file is there.
    ///
    /// The volume rule, and its own trap: an external drive lives under `/Volumes/<name>`, and a
    /// path there whose volume is not mounted is NOT a lost file — the file is on the drive, the
    /// drive is in a drawer. But the BOOT volume is not under `/Volumes` at all: everything under
    /// `/Users`, `/Applications`, `/private`… is on a disk that is by definition mounted, so it
    /// falls through to `.absent` and must never be reported as offline. Only the `/Volumes`
    /// prefix arms the question, and only a `/Volumes/<name>` that is not there as a DIRECTORY
    /// answers it 'offline' (a mounted volume is a directory; `fileExists` follows the symlink
    /// macOS puts there for the boot volume, so `/Volumes/Macintosh HD/…` reads as mounted, which
    /// it is).
    nonisolated static func missingReason(ofFileAt path: String) -> MissingReason? {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return nil }

        let parts = (path as NSString).pathComponents        // ["/", "Volumes", "<name>", …]
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return .absent }
        let volumeRoot = "/Volumes/" + parts[2]
        var isDirectory: ObjCBool = false
        let mounted = fm.fileExists(atPath: volumeRoot, isDirectory: &isDirectory)
        return (mounted && isDirectory.boolValue) ? .absent : .volumeOffline
    }

    // MARK: - Watching the volumes

    /// Subscribes to volumes being mounted and unmounted, each of which rescans. It is what makes
    /// `.volumeOffline` a state that mends itself: plug the drive back in and the red goes,
    /// without anybody having to reopen the project.
    ///
    /// Both notifications matter, and for opposite reasons — a mount can FIX things, an unmount
    /// can break things while the project sits open — so the same scan answers both.
    ///
    /// Idempotent: called twice it does nothing the second time. Two subscriptions would mean two
    /// scans per event, i.e. twice the disk for the same answer. The tokens are kept (see the
    /// table at the head of this file) so the watch can be handed back — the repo's rule for a
    /// monitor is that whoever lays it down takes it up again (@see `disarmMissingFileWatch`).
    func armMissingFileWatch() {
        let key = ObjectIdentifier(self)
        guard missingFileWatchTokens[key] == nil else { return }
        // NSWorkspace's OWN notification centre, not `NotificationCenter.default`: the mount
        // notifications are posted there and nowhere else, and an observer registered on the
        // default centre would simply never fire.
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didMountNotification,
                                          NSWorkspace.didUnmountNotification]
        missingFileWatchTokens[key] = names.map { name in
            // `queue: .main` → the block runs on the main thread, which is what lets it touch the
            // view-model at all. Weak: the watch must not be what keeps a document alive.
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rescanMissingFiles()
                }
            }
        }
    }

    /// Takes the watch back down. Idempotent, like the arming.
    func disarmMissingFileWatch() {
        let key = ObjectIdentifier(self)
        guard let tokens = missingFileWatchTokens.removeValue(forKey: key) else { return }
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
    }
}

import Foundation
import AppKit

// MARK: - Source files that changed on disk (detection + silent reload)
//
// A take re-saved by an audio editor, a bounce exported over itself: the project names the same
// path and the content behind it is no longer the one the app decoded. Two things went on showing
// the old file — the waveform (the memory cache never noticed anything) and the engine (Tracktion
// keys its derived files, the reversed render and the proxy of a compressed format, by a hash of
// the PATH, so they stay stale on a content change). This file is the half that notices and
// mends, silently; its pure half (what counts as "changed") is `FileChangeDetection`.
//
// **AS SPARING AS POSSIBLE, and that is the design.** No watcher, no timer polling the disk, no
// hash: ONE `stat` (size + mtime) per DISTINCT path, off the main thread, at three moments only —
//   1. a project is opened;
//   2. the application comes back to the foreground (2 s anti-bounce, `fileChangeAntiBounce`);
//   3. a tab comes back to the front (only that tab's paths — its objects are the only ones named).
// No detection on a volume mounting, no menu command, no button: the user asked for none.
//
// **The reload is SILENT** (no toast, no alert) and **OUTSIDE the undo history, without marking
// the project dirty**: the document did not change, the disk under it did — it is the same kind of
// fact as `rescanMissingFiles`, and an undo point for it would leave ⌘Z undoing something the user
// never did. (The cost, written down: an undo snapshot taken before the reload still holds the
// old `fileDuration` and window; undoing across a reload rebuilds the object on the file as it is.)
//
// **What a reload does** (`reloadChangedSources`), once per PATH however many objects share it:
//   - purge the engine's derived files and force its AudioFile to re-read the source
//     (`OBJEngineCore.refreshSourceFile`) — BEFORE the clips are touched, because the purge finds
//     the reversed render and the proxy through the live clips;
//   - rebuild each object on the file (`refreshClip` → `relaunchClip`, the relink's own sequence):
//     the window is fitted to the new length (`fittedWindow` — a shorter file slides the window
//     back, then crops it, the fades following) and `fileDuration` / `fileSize` are updated;
//   - empty the waveform cache for the path and read it again.
//
// **What is NOT reloaded**: an object carrying an ARA source (Melodyne) — relaunching its analysis
// would drop the retouches; its waveform is refreshed, its engine clip is left as it is. An
// instance of a consolidated object (the app wrote that wave itself) and anything under the
// project's own `samples/consolidate|objects|sources` folders (`FileChangeDetection.isAppWritten`).
//
// **When it is not the moment** — playback running, a project loading, an export or a bake in
// flight, a consolidated object open for editing, a tab switch under way (`fileChangeBlocker`, the
// tab switch's own refusal list plus the transport): nothing is read or applied, `rescanWanted` is
// set, and the work is redone from scratch when the obstacle goes — at the stop for the transport
// (`ObjekatSession.isPlaying`'s `didSet` → `flushPendingFileChanges`), through a 1 s retry for the
// rest, armed only while something waits. A deferred scan costs nothing but being run later.
//
// **Identities are PER DOCUMENT.** The single `EditViewModel` serves every tab, so what it knows
// (`fileChanges.known`) travels with the tab (`ParkedProject.fileIdentities`) and comes back with
// it: a file changed while its tab was parked is then caught on the way back, against what the tab
// knew when it left. A path the DOCUMENT never saw falls back on what the PROCESS saw, in this
// order: the identity the last scan of any document learned for it (`FileChangeTracker.seen`), the
// identity its peaks were decoded from if the memory waveform cache still holds them
// (`waveformStamps`), and a clip's recorded `fileSize` (partially populated: FolderImport, relink,
// `object.add`, a baseline of size alone). Without the first two, a project closed and reopened in
// the same run learned the rewritten file as new — the engine kept its old reading and the memory
// cache its old peaks, which only quitting the app cleared (21 October 2026). A path nobody in this
// process has seen is learned, never reloaded on a guess.

/// Why a scan is run — only to tell the triggers apart in a report and to decide the anti-bounce.
enum FileChangeScanReason: String, Sendable {
    case open, foreground, tabReturn, deferred, api
}

/// What one `checkChangedFiles` did. Plain values, so a script can assert on it.
struct FileChangeReport: Sendable {
    var reason: FileChangeScanReason
    /// Distinct paths asked of the disk (one `stat` each).
    var scanned = 0
    /// Paths found changed, in project order.
    var changed: [String] = []
    /// Paths actually reloaded (changed AND readable).
    var reloadedPaths: [String] = []
    /// Objects rebuilt on their file.
    var reloadedObjects = 0
    /// Objects left alone because they carry an ARA source.
    var araSkipped = 0
    /// Changed paths the app could not open (a file caught mid-write): left for the next scan.
    var unreadable: [String] = []
    /// Why the scan did not run now (`transport`, `loading`, …) — it is redone when that clears.
    var deferredBy: String? = nil
    /// Why the scan did not run at all (`anti_bounce`, `in_flight`, `no_files`, `document_changed`).
    var skipped: String? = nil

    var json: JSONValue {
        .object(["reason": .string(reason.rawValue),
                 "scanned": .int(scanned),
                 "changed": .array(changed.map { .string($0) }),
                 "reloaded_paths": .array(reloadedPaths.map { .string($0) }),
                 "reloaded_objects": .int(reloadedObjects),
                 "ara_skipped": .int(araSkipped),
                 "unreadable": .array(unreadable.map { .string($0) }),
                 "deferred_by": deferredBy.map { .string($0) } ?? .null,
                 "skipped": skipped.map { .string($0) } ?? .null])
    }
}

/// The mutable state of the detection, kept in ONE reference because an extension cannot carry
/// stored properties. Invisible to the observation (`EditViewModel.fileChanges` is
/// `@ObservationIgnored`): no view draws any of it.
@MainActor
final class FileChangeTracker {
    /// path → identity as of the last scan that saw it, for the document in front.
    var known: [String: SourceFileIdentity] = [:]
    /// Bumped each time the document in front changes (a load finishing, a tab being parked): a
    /// scan started under another epoch answers about a document that is gone and is discarded.
    var epoch = 0
    /// The epoch of the scan whose stats are under way, if any.
    var scanningEpoch: Int?
    /// Scans requested and not yet finished — counted from the moment of the request, so
    /// `wait_idle` cannot see a gap between "asked" and "started".
    var queued = 0
    /// A scan was refused for lack of a good moment and must be redone.
    var rescanWanted = false
    var retryArmed = false
    /// Between `parkProject()` and the load that follows it, the document is neither one nor the
    /// other: nothing may be applied.
    var documentParked = false
    /// Handed from `restoreParkedProject` to `performFinalize` across the load in between.
    var carried: [String: SourceFileIdentity]?
    var lastScan: Date?
    var activationToken: NSObjectProtocol?

    /// path → identity as of the last scan that saw it, for ANY document of this process: the
    /// engine's readings and the memory waveform cache are the process's, not a document's, so a
    /// file rewritten while its project was closed must be judged against them.
    static var seen: [String: SourceFileIdentity] = [:]

    var isBusy: Bool { queued > 0 || scanningEpoch != nil }
}

extension EditViewModel {

    /// Two foreground notifications closer than this are one scan.
    static let fileChangeAntiBounce: TimeInterval = 2
    /// How long a deferred scan waits before it looks again (only while one is waiting).
    private static let fileChangeRetryDelay: TimeInterval = 1

    // MARK: - The moment

    /// Why a scan cannot run NOW, or nil. The tab switch's refusal list (`tabSwitchBlocker`: a
    /// load, a direct export, a bake, a consolidated object open for editing) plus the transport
    /// and the gap between parking a tab and loading the next. A short word for a report.
    var fileChangeBlocker: String? {
        if isTransportRunning { return "transport" }
        if fileChanges.documentParked { return "tab_switch" }
        if let key = tabSwitchBlocker {
            let prefix = "tabs.switch.refused."
            return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
        }
        return nil
    }

    // MARK: - Triggers

    /// Subscribes to the application coming back to the foreground. Idempotent. The first
    /// activation of a launch usually lands right after the opening scan and is swallowed by the
    /// anti-bounce (any scan, whatever its reason, restarts the 2 s).
    func armFileChangeWatch() {
        guard fileChanges.activationToken == nil else { return }
        fileChanges.activationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescanChangedFiles(reason: .foreground) }
        }
    }

    /// Fire and forget: runs `checkChangedFiles` as a task. The request is counted as pending
    /// synchronously, so `Quiescence` never sees a hole before the task starts.
    func rescanChangedFiles(reason: FileChangeScanReason) {
        fileChanges.queued += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fileChanges.queued -= 1 }
            _ = await self.checkChangedFiles(reason: reason)
        }
    }

    /// Called when the transport stops (and pauses): redoes what was put off during playback.
    func flushPendingFileChanges() {
        guard fileChanges.rescanWanted else { return }
        rescanChangedFiles(reason: .deferred)
    }

    /// Armed only while a scan is waiting for something other than the transport (the transport
    /// has its own flush at the stop, and a timer ticking through a long playback would be the
    /// kind of polling this feature promises not to do).
    private func armFileChangeRetry() {
        guard !fileChanges.retryArmed else { return }
        fileChanges.retryArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fileChangeRetryDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fileChanges.retryArmed = false
                guard self.fileChanges.rescanWanted else { return }
                self.rescanChangedFiles(reason: .deferred)
            }
        }
    }

    // MARK: - The scan

    /// Asks the disk about every distinct source path the project names, and reloads the ones
    /// that changed. The whole detection, awaitable (the command API waits on it).
    @discardableResult
    func checkChangedFiles(reason: FileChangeScanReason) async -> FileChangeReport {
        let tracker = fileChanges
        var report = FileChangeReport(reason: reason)

        if reason == .foreground, let last = tracker.lastScan,
           Date().timeIntervalSince(last) < Self.fileChangeAntiBounce {
            report.skipped = "anti_bounce"
            return report
        }
        if let why = fileChangeBlocker { return deferScan(report, because: why) }
        if tracker.scanningEpoch == tracker.epoch {
            report.skipped = "in_flight"
            return report
        }

        // The questions, from the model, on the main thread: a walk of the tree and nothing else.
        let inputs = fileChangeInputs()
        guard !inputs.paths.isEmpty else {
            report.skipped = "no_files"
            tracker.rescanWanted = false
            return report
        }
        report.scanned = inputs.paths.count
        tracker.lastScan = Date()
        tracker.scanningEpoch = tracker.epoch
        let epoch = tracker.epoch
        defer { if tracker.scanningEpoch == epoch { tracker.scanningEpoch = nil } }
        WaveformCacheMeter.record { $0.fileChangeScans += 1 }

        // The stats: off the main thread, lowest priority, one per path.
        let paths = inputs.paths
        let statStart = CFAbsoluteTimeGetCurrent()
        let after = await Task.detached(priority: .utility) {
            FileChangeDetection.identities(ofFilesAt: paths)
        }.value
        let statSeconds = CFAbsoluteTimeGetCurrent() - statStart
        WaveformCacheMeter.record {
            $0.fileChangeStats += paths.count
            $0.fileChangeStatSeconds += statSeconds
        }

        // Back on the main thread, and the world may have moved while the stats ran: another
        // document (the answer is about a project that is gone), or a moment that is no longer
        // good (the hand pressed play).
        guard tracker.epoch == epoch else {
            report.skipped = "document_changed"
            return report
        }
        if let why = fileChangeBlocker { return deferScan(report, because: why) }

        // What was known, completed for the paths this document never saw: what the process saw,
        // then what the memory waveform cache decoded, then the sizes the model recorded.
        var before = tracker.known
        for path in paths where before[path] == nil {
            if let seen = FileChangeTracker.seen[path] { before[path] = seen }
        }
        let unseen = paths.filter { before[$0] == nil }
        if !unseen.isEmpty, let stamps = waveformStamps?(unseen) {
            for (path, stamp) in stamps {
                // The cache reads its time through Foundation, the scan through `stat` with its
                // nanoseconds: the same file must not read as changed for a rounding.
                if let now = after[path] ?? nil, let t = now.mtime, let s = stamp.mtime,
                   now.size == stamp.size, abs(t - s) < 1e-3 {
                    before[path] = now
                } else {
                    before[path] = stamp
                }
            }
        }
        for (path, size) in inputs.recordedSizes where before[path] == nil {
            before[path] = SourceFileIdentity(size: size, mtime: nil)
        }
        let changed = FileChangeDetection.changedPaths(objectPaths: paths, before: before, after: after)
        report.changed = changed

        // Learn everything reachable that did not change (new paths, and the size-only baselines
        // gaining their time). A changed path is learned by its reload, once it has succeeded.
        let changedSet = Set(changed)
        for path in paths where !changedSet.contains(path) {
            if let now = after[path] ?? nil {
                tracker.known[path] = now
                FileChangeTracker.seen[path] = now
            }
        }

        if !changed.isEmpty {
            let outcome = reloadChangedSources(changed, identities: after)
            report.reloadedPaths = outcome.reloadedPaths
            report.reloadedObjects = outcome.objects
            report.araSkipped = outcome.araSkipped
            report.unreadable = outcome.unreadable
        }
        tracker.rescanWanted = false
        return report
    }

    /// A scan that is not for now: remembered, counted, and — unless the transport is what it
    /// waits for — retried shortly.
    private func deferScan(_ report: FileChangeReport, because why: String) -> FileChangeReport {
        var report = report
        report.deferredBy = why
        fileChanges.rescanWanted = true
        WaveformCacheMeter.record { $0.fileChangeDeferred += 1 }
        if why != "transport" { armFileChangeRetry() }
        return report
    }

    // MARK: - The questions

    /// The distinct source paths to ask the disk about, and the sizes the model recorded for them.
    /// Excludes instances of consolidated objects (their wave is the app's own) and anything under
    /// the project's app-written folders.
    private func fileChangeInputs() -> (paths: [String], recordedSizes: [String: Int64]) {
        var objectPaths: [String] = []
        var sizes: [String: Int64] = [:]
        for clip in allClips {
            guard case .clip(let path, _, _, _, _) = clip.kind, !path.isEmpty,
                  clip.consolidateID == nil else { continue }
            objectPaths.append(path)
            if sizes[path] == nil, let size = clip.fileSize { sizes[path] = size }
        }
        var folders: [String] = []
        if let project = projectFolder {
            for sub in ConsolidateFolders.audioSubfolders {
                let folder = project.appendingPathComponent(sub, isDirectory: true)
                folders.append(folder.path)
                let resolved = folder.resolvingSymlinksInPath().path
                if resolved != folder.path { folders.append(resolved) }
            }
        }
        let paths = FileChangeDetection.scanPaths(objectPaths: objectPaths, appWrittenFolders: folders)
        return (paths, sizes)
    }

    // MARK: - The reload

    /// Reloads the changed paths — the engine, the model, the waveform — once per path. Runs on
    /// the main thread, under the engine's own rule (Tracktion is mutated from there only).
    private func reloadChangedSources(_ changed: [String], identities: [String: SourceFileIdentity?])
        -> (reloadedPaths: [String], objects: Int, araSkipped: Int, unreadable: [String]) {
        let started = CFAbsoluteTimeGetCurrent()
        let changedSet = Set(changed)
        var idsByPath: [String: [UUID]] = [:]
        var araSkipped = 0
        for clip in allClips {
            guard case .clip(let path, _, _, _, _) = clip.kind, changedSet.contains(path),
                  clip.consolidateID == nil else { continue }
            if clip.araSource != nil { araSkipped += 1; continue }
            idsByPath[path, default: []].append(clip.id)
        }

        var reloaded: [String] = []
        var unreadable: [String] = []
        var objects = 0
        for path in changed {
            guard let identity = identities[path] ?? nil else { continue }
            // A file the app cannot open (caught while its writer is still at it) is left alone
            // and NOT learned: the next scan sees it changed again and tries again.
            guard let length = audioFileDuration(URL(fileURLWithPath: path)) else {
                unreadable.append(path)
                continue
            }
            ClipChannels.forget(atPath: path)
            ClipSourceFormat.forget(atPath: path)
            let ids = idsByPath[path] ?? []
            if !ids.isEmpty {
                // Once per path, BEFORE any clip is rebuilt (the purge finds the derived files
                // through the live clips).
                engine?.refreshSourceFile(atPath: path)
                for id in ids where refreshClip(id: id, onFile: path, fileLength: length, size: identity.size) {
                    objects += 1
                }
            }
            fileChanges.known[path] = identity
            FileChangeTracker.seen[path] = identity
            reloaded.append(path)
            WaveformCacheMeter.record { $0.fileChangeReloads += 1 }
        }
        if !reloaded.isEmpty { invalidateWaveforms?(reloaded) }
        let seconds = CFAbsoluteTimeGetCurrent() - started
        WaveformCacheMeter.record { $0.fileChangeReloadSeconds += seconds }
        return (reloaded, objects, araSkipped, unreadable)
    }

    /// ONE object laid again on the SAME file, which has changed: the relink's rebuild without its
    /// path guard, undo point or dirty flag, taking the live state of its plugins with it (the
    /// object is alive, unlike a relinked ghost). The window is fitted to the new length.
    @discardableResult
    func refreshClip(id: UUID, onFile path: String, fileLength: Double?, size: Int64?) -> Bool {
        relaunchClip(id: id, onFile: path, fileLength: fileLength, size: size,
                     capturingLiveState: true)
    }
}

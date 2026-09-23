import Foundation

// MARK: - Consolidate folders — the disk half of "objet consolidé", with no dependency at all
//
// A consolidated object's wave and sidecar live in `samples/consolidate/` from here on (new
// writes). Every project saved before this file existed wrote into `samples/objects/`, and stays
// readable there for ever: nothing is migrated automatically (see `plan_consolidate.md`, cas E1 —
// several `.json` versions can share one `samples/`, archived old builds still look in
// `objects/`, and opening a project must never write to disk on its own).
//
// This unit is the reason `PathRelink` / `SendColumns` / `PianoRollFraming` / `ComposedName` /
// `CutSelection` are units of their own: it is the half of "where does a wave live" that touches
// no model and no disk by itself — `fileExists` is injected — so it compiles alone and is
// asserted with no screen (@see tools/test_consolidate_folders.swift).

enum ConsolidateFolders {

    /// The sub-folder name new writes go to, under `samples/`.
    static let folderName = "consolidate"
    /// The sub-folder name old projects wrote to. Read for ever, never written again.
    static let legacyFolderName = "objects"

    /// `<projectFolder>/samples/consolidate` — the folder new bakes write into.
    static func consolidateFolder(projectFolder: URL) -> URL {
        projectFolder.appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// `<projectFolder>/samples/objects` — the legacy folder, read-only from here on.
    static func legacyFolder(projectFolder: URL) -> URL {
        projectFolder.appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent(legacyFolderName, isDirectory: true)
    }

    /// Every folder a wave named `wave` might be found in, in PRIORITY order (cas E18 — the
    /// names carry a UUID + `_vN`, so no collision between the two folders is realistic; the order
    /// only matters the day it somehow is):
    /// 1. `samples/consolidate/` — new writes always win;
    /// 2. `samples/objects/` — the legacy folder (cas E1);
    /// 3. `extraDirs`, appended as given — the Q3 fallback (an existing instance's own folder,
    ///    which the caller computes from the model: this unit knows nothing of placements).
    static func waveCandidates(projectFolder: URL, extraDirs: [URL] = []) -> [URL] {
        [consolidateFolder(projectFolder: projectFolder), legacyFolder(projectFolder: projectFolder)]
            + extraDirs
    }

    /// The folder `wave` is ACTUALLY found in, trying `waveCandidates` in order and keeping the
    /// first one `fileExists` answers true for. `fileExists` is injected precisely so this can be
    /// asserted with no disk at all (@see tools/test_consolidate_folders.swift). `nil` if `wave` is
    /// found in none of the candidates — the caller then falls back on the write folder.
    static func resolve(wave: String, projectFolder: URL, extraDirs: [URL] = [],
                        fileExists: (URL) -> Bool) -> URL? {
        for dir in waveCandidates(projectFolder: projectFolder, extraDirs: extraDirs) {
            if fileExists(dir.appendingPathComponent(wave)) { return dir }
        }
        return nil
    }

    // MARK: - `ProjectPaths`' own fallback (cas E2, E16)
    //
    // The project folder's audio sub-folders, in resolution order: `consolidate` wins a
    // collision (cas E18), `objects` stays readable, `sources` is a capsule's embedded sources
    // (@see `EditViewModel+SaveCopy.swift`) and has nothing to do with consolidation.
    static let audioSubfolders = ["samples/\(folderName)", "samples/\(legacyFolderName)", "samples/sources"]

    /// "samples/objects/x.wav" → "samples/consolidate/x.wav". `nil` for anything else: only a
    /// relative path that explicitly names the LEGACY folder is worth trying under the new one
    /// (`ProjectPaths.resolved`'s own repli, cas E2/E16).
    static func swappedToConsolidate(_ relativePath: String) -> String? {
        let prefix = "samples/\(legacyFolderName)/"
        guard relativePath.hasPrefix(prefix) else { return nil }
        return "samples/\(folderName)/" + relativePath.dropFirst(prefix.count)
    }
}

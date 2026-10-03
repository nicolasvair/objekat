import Foundation

/// Where the "Save as" panel opens — the one rule, with no AppKit and no model, so it can be
/// compiled and asserted alone (`tools/test_save_as_start_folder.swift`).
///
/// It used to be nothing at all: the panel was given no `directoryURL`, so AppKit showed whatever
/// folder ITS OWN panels had last been in. A project opened from "Recent projects", from the
/// Finder, by a tab switch or by a reload never went through a panel, so Save As came up in a
/// folder that had nothing to do with the project one was looking at.
///
/// The rule has two cases, and they differ on purpose:
///   • a project that has a file → ITS folder. That is where its versions live, so a Save As there
///     lays "V2" beside "V1" and shares `samples/` and `waveforms/` (@see
///     `EditViewModel.saveAsFileURL`, which writes the manifest in place when the chosen folder is
///     already a project).
///   • an UNTITLED project (a new project, a new tab) → the PARENT of the last project folder
///     seen. Proposing the project's own folder here would be a trap: a name typed there would
///     put an unrelated project's manifest INSIDE another project's folder, sharing its media,
///     where what one wants is a sibling folder of its own.
/// Nil = no opinion (nothing seen yet, or the folder is gone): the panel keeps AppKit's default.
nonisolated enum SaveAsStartFolder {

    /// - Parameters:
    ///   - projectURL: the version file of the project being saved, nil while it has none.
    ///   - lastProjectFolder: the folder of the last project opened or saved in this process
    ///     (or the head of "Recent projects"), nil if none.
    ///   - isUsableFolder: whether a folder can be offered (it exists and is a directory) —
    ///     injected so the rule can be asserted without a disk.
    static func resolve(projectURL: URL?,
                        lastProjectFolder: URL?,
                        isUsableFolder: (URL) -> Bool = SaveAsStartFolder.existsAsDirectory) -> URL? {
        if let projectURL {
            let folder = projectURL.deletingLastPathComponent()
            if isUsableFolder(folder) { return folder }
        }
        if let lastProjectFolder {
            let parent = lastProjectFolder.deletingLastPathComponent()
            if isUsableFolder(parent) { return parent }
        }
        return nil
    }

    static func existsAsDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

import Foundation

// MARK: - Importing a folder as a group

/// `object.import_folder` — the scriptable twin of dropping a folder on the timeline. The rules
/// (what is read, how it is laid out, how a group's bounds are drawn) are `FolderImport`'s; the
/// laying down is `EditViewModel.placeDropEntries`, the very function the drop calls.
extension CommandRegistry {

    func registerImportFolderCommands() {

        register("object.import_folder",
                 summary: "Imports a FOLDER as one folded group named after it, the hierarchy kept: "
                        + "one lane per audio file and per sub-folder (each sub-folder a folded "
                        + "sub-group), always recursive, hidden files and packages ignored, "
                        + "folders with no audio left out. Returns the tree of ids.",
                 params: [ParamSpec("path", "string", "Path of the folder."),
                          ParamSpec("lane", "int", required: false,
                                    "Target display lane (default 0). Inside an OPEN group's band, "
                                  + "the group is laid in it, like a drop there."),
                          ParamSpec("start", "number", required: false,
                                    "Start, in seconds (default 0)."),
                          ParamSpec("mode", "string", required: false,
                                    "'stacked' (default): same start, one lane per file and per "
                                  + "sub-folder. 'sequential': one lane, end to end — the drop's ⌘.")],
                 // The bus pushes ONE undo point around the handler: the whole import is one ⌘Z.
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let path = try p.string("path")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                throw CommandError(code: .not_found, message: "folder not found: \(path)")
            }
            guard isDir.boolValue else {
                throw CommandError(code: .bad_params, message: "not a folder: \(path) (use object.add for a file)")
            }
            let mode: EditViewModel.FileDropMode
            switch try p.string("mode", or: "stacked") {
            case "stacked":    mode = .stacked
            case "sequential": mode = .sequential
            case let other:
                throw CommandError(code: .bad_params,
                                   message: "unknown mode '\(other)' (expected 'stacked' or 'sequential')")
            }
            let lane = max(0, try p.int("lane", or: 0))
            let start = max(0, try p.double("start", or: 0))

            // Read and measured off the main thread. NEVER asks for a confirmation: a script that
            // names a folder means it (the dialog is the drop's, for a hand that slipped).
            let scan = await EditViewModel.loadFolder(URL(fileURLWithPath: path))
            guard let root = scan.root else {
                switch scan.failure {
                case .tooManyFiles(let n):
                    throw CommandError(code: .bad_params,
                                       message: "too many audio files (more than \(FolderImport.maxFiles), "
                                              + "stopped counting at \(n)): \(path)",
                                       details: .object(["max_files": .int(FolderImport.maxFiles)]))
                default:
                    throw CommandError(code: .invalid_state, message: "no audio file in \(path)")
                }
            }
            let placed = vm.placeDropEntries([.folder(root)], baseLane: lane, baseStart: start, mode: mode)
            guard let groupID = placed.first, vm.find(id: groupID) != nil else {
                throw CommandError(code: .internal_error, message: "nothing was created")
            }
            var result: [String: JSONValue] = [
                "id": .string(groupID.uuidString),
                "parent": .stringOrNull(vm.parentGroup(for: groupID)?.id.uuidString),
                "files": .int(root.fileCount),
                "omitted_deep_folders": .int(scan.omittedDeepFolders),
                "mode": .string(mode == .stacked ? "stacked" : "sequential"),
            ]
            if case .object(let tree) = vm.placedTree(of: groupID) {
                result["tree"] = .object(tree)
                for key in ["lane", "start", "duration"] { result[key] = tree[key] }
            }
            return .object(result)
        }
    }
}

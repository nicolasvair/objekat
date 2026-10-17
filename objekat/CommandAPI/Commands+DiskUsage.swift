import Foundation

// MARK: - Disk usage of the project folder, and its clean-up

/// `project.disk_usage` reads the figures the sound list's footer shows, `project.clean_unused`
/// sends the unused files to the Trash — the same function the popover calls
/// (`EditViewModel.cleanUnusedFiles`), with one difference of default: through the API a call is a
/// DRY RUN unless it says otherwise, because a script has no confirmation dialogue to hide behind.
extension CommandRegistry {

    func registerDiskUsageCommands() {

        register("project.disk_usage",
                 summary: "What the project folder weighs and how much of it nothing reads any more "
                        + "(old revisions of consolidated waves, embedded sources, orphan waveform "
                        + "caches). Recomputes by default; refused with invalid_state for a project "
                        + "never saved.",
                 params: [ParamSpec("scope", "string", required: false,
                                    "`session` (default): what THIS session does not read, files "
                                  + "another version of the folder reads being listed apart in "
                                  + "`held`. `folder`: what NO version reads — answers "
                                  + "`cleanable: null` while a version of the folder cannot be read."),
                          ParamSpec("refresh", "bool", required: false,
                                    "false = answer with the figures already held, without a new scan.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let scope = try Self.diskScope(p)
            guard vm.projectFolder != nil, vm.projectURL != nil else {
                throw CommandError(code: .invalid_state, message: "save the project first: it has no folder yet")
            }
            let refresh = try p.bool("refresh", or: true)
            var result = vm.diskUsage
            if refresh { result = await vm.computeDiskUsage() ?? vm.diskUsage }
            guard let result else {
                throw CommandError(code: .invalid_state,
                                   message: vm.diskUsageBlockedKey.map { "the folder cannot be read now (\($0))" }
                                          ?? "no figures yet")
            }
            return Self.diskUsageJSON(result, scope: scope, blocked: vm.diskUsageBlockedKey)
        }

        register("project.clean_unused",
                 summary: "Sends the files nothing reads any more to the TRASH (never deletes). A dry run "
                        + "unless `dry_run` is false. Everything is recomputed right before; a path that "
                        + "is not on the fresh list of cleanable files is reported in `rejected` with "
                        + "its bucket (`used`, `protected`, `held`, `unknown`) and never touched. "
                        + "Refused (invalid_state, nothing moved) for a project never saved, while a "
                        + "load, a bake or a consolidated edit is under way, and in `folder` scope "
                        + "while a version of the folder cannot be read. Undoing afterwards fetches a "
                        + "cleaned file back from the Trash when the restored state reads it again.",
                 params: [ParamSpec("scope", "string", required: false, "`session` (default) or `folder`."),
                          ParamSpec("paths", "array<string>", required: false,
                                    "The folder-relative `path`s to clean (as `project.disk_usage` lists them). "
                                  + "Absent = every cleanable unit."),
                          ParamSpec("dry_run", "bool", required: false,
                                    "true by default: say what would move, move nothing.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let scope = try Self.diskScope(p)
            let dryRun = try p.bool("dry_run", or: true)
            var selection: Set<String>?
            if p.raw["paths"] != nil {
                selection = Set(try p.array("paths").map { element -> String in
                    guard let s = element.stringValue else {
                        throw CommandError(code: .bad_params, message: "parameter 'paths': a list of strings was expected")
                    }
                    return s
                })
            }
            let outcome = await vm.cleanUnusedFiles(selection: selection, scope: scope, dryRun: dryRun)
            if let refusal = outcome.refusal {
                var details: [String: JSONValue] = ["reason": .string(refusal.apiCode)]
                if case .busy(let key) = refusal { details["busy"] = .string(key) }
                if case .unreadableVersions(let names) = refusal {
                    details["unreadable_versions"] = .array(names.map { .string($0) })
                }
                throw CommandError(code: .invalid_state, message: "nothing moved: \(refusal.apiCode)",
                                   details: .object(details))
            }
            let units: [JSONValue] = outcome.units.map { unit in
                var o: [String: JSONValue] = [
                    "path": .string(unit.id),
                    "kind": .string(unit.kind.rawValue),
                    "size": .int(Int(unit.size)),
                    "files": .array(unit.files.map { .string($0) }),
                ]
                if !dryRun, let trashed = vm.trashedFileUnits[unit.id] {
                    o["trash"] = .array(trashed.files.map { .string($0.trash.path) })
                }
                return .object(o)
            }
            return .object([
                "dry_run": .bool(dryRun),
                "scope": .string(scope.rawValue),
                (dryRun ? "would_trash" : "trashed"): .array(units),
                "count": .int(units.count),
                "bytes": .int(Int(outcome.bytes)),
                "rejected": .array(outcome.rejected.map {
                    .object(["path": .string($0.id), "reason": .string($0.reason)])
                }),
                "failed": .array(outcome.failed.map {
                    .object(["path": .string($0.id), "message": .string($0.message)])
                }),
            ])
        }
    }

    private static func diskScope(_ p: CommandParams) throws -> DiskCleanScope {
        let name = try p.string("scope", or: DiskCleanScope.session.rawValue)
        guard let scope = DiskCleanScope(rawValue: name) else {
            throw CommandError(code: .bad_params, message: "parameter 'scope': 'session' or 'folder' expected, got '\(name)'")
        }
        return scope
    }

    private static func candidateJSON(_ c: ProjectFileUsage.Candidate, versions: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "path": .string(c.id),
            "name": .string(c.name),
            "kind": .string(c.kind.rawValue),
            "folder": .string(c.folder),
            "size": .int(Int(c.size)),
            "files": .array(c.files.map { .string($0) }),
        ]
        if let versions { o["versions"] = .array(versions.map { .string($0) }) }
        return .object(o)
    }

    private static func diskUsageJSON(_ r: DiskUsageResult, scope: DiskCleanScope, blocked: String?) -> JSONValue {
        let report = r.report
        let cleanable = r.cleanable(in: scope)
        return .object([
            "folder": .string(r.folder.path),
            "scope": .string(scope.rawValue),
            "total_bytes": .int(Int(r.totalBytes)),
            "used_bytes": .int(Int(report.usedBytes)),
            "unused_bytes": .int(Int(cleanable == nil ? 0 : report.unusedBytes)),
            "held_bytes": .int(Int(report.heldBytes)),
            "protected_bytes": .int(Int(report.protectedBytes)),
            "cleanable": cleanable.map { list in .array(list.map { candidateJSON($0) }) } ?? .null,
            "held": .array(report.held.map { candidateJSON($0.candidate, versions: $0.versions) }),
            "protected": .array(report.protected.map { candidateJSON($0) }),
            "versions": .array(r.versionNames.map { .string($0) }),
            "unreadable_versions": .array(r.unreadableVersions.map { .string($0) }),
            "blocked": blocked.map { .string($0) } ?? .null,
            "computed_at": .number(r.computedAt.timeIntervalSince1970),
        ])
    }
}

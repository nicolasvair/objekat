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
                                    "`session` (default): EVERYTHING this session does not read, "
                                  + "including the files another version of the folder still reads "
                                  + "(`cleanable` units carrying `used_by`, listed in `used_elsewhere` "
                                  + "too); an unreadable version does not stand in the way. `folder`: "
                                  + "only what NO version reads — answers `cleanable: null` while a "
                                  + "version of the folder cannot be read."),
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
                        + "its bucket (`used`, `protected`, `used_elsewhere` in `folder` scope, "
                        + "`unknown`) and never touched. In `session` scope a file another version "
                        + "reads IS cleanable when named in `paths` (the units then carry `used_by`: "
                        + "those versions will show it missing); without `paths` only the files "
                        + "nobody reads are taken. "
                        + "Refused (invalid_state, nothing moved) for a project never saved, while a "
                        + "load, a bake or a consolidated edit is under way, and in `folder` scope "
                        + "while a version of the folder cannot be read. Undoing afterwards fetches a "
                        + "cleaned file back from the Trash when the restored state reads it again.",
                 params: [ParamSpec("scope", "string", required: false, "`session` (default) or `folder`."),
                          ParamSpec("paths", "array<string>", required: false,
                                    "The folder-relative `path`s to clean (as `project.disk_usage` lists them). "
                                  + "Absent = every unit NOBODY reads (never the ones another version "
                                  + "reads: those must be named)."),
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
                if let versions = outcome.usedBy[unit.id] { o["used_by"] = .array(versions.map { .string($0) }) }
                if !dryRun, let trashed = vm.trashedFileUnits[unit.id] {
                    o["trash"] = .array(trashed.files.map { .string($0.trash.path) })
                }
                return .object(o)
            }
            return .object([
                "dry_run": .bool(dryRun),
                "used_by_other_versions": .int(outcome.usedBy.count),
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

    /// `project.convert_to_flac` — the archive conversion of the clean-up popover, for a script.
    func registerFlacArchiveCommands() {
        register("project.convert_to_flac",
                 summary: "Converts to FLAC, WITHOUT LOSS, the WAV files of the project folder that the "
                        + "project reads (consolidated objects' rendered waves and embedded sources) and "
                        + "re-aims the project onto them; the project becomes modified (no undo point). "
                        + "A dry run unless `dry_run` is false. Integer 16/24-bit WAV -> FLAC of the same "
                        + "depth (bit-exact); floating-point WAV -> FLAC 24 only if its peak is <= 0 dBFS; "
                        + "anything else (a peak above 0 dBFS, more than 8 channels, another depth, an "
                        + "unreadable file, a source a consolidated object's content reads, an ARA source) "
                        + "stays a WAV and is listed in `kept` with its `reason`. A FLAC is read back and "
                        + "compared with its WAV before anything points at it. The original WAVs are NOT "
                        + "deleted: after a save they are read by nobody and `project.clean_unused` offers "
                        + "them. Files outside the project folder are never touched (`outside_count`). "
                        + "Refused (invalid_state, nothing changed) for a project never saved and while a "
                        + "load, a render, an export or a consolidated edit is under way.",
                 params: [ParamSpec("dry_run", "bool", required: false,
                                    "true by default: say what would be converted, write nothing.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let dryRun = try p.bool("dry_run", or: true)
            let outcome = await vm.convertAudioToFlac(dryRun: dryRun)
            if let refusal = outcome.refusal {
                var details: [String: JSONValue] = ["reason": .string(refusal.apiCode)]
                if case .busy(let key) = refusal { details["busy"] = .string(key) }
                throw CommandError(code: .invalid_state, message: "nothing changed: \(refusal.apiCode)",
                                   details: .object(details))
            }
            let converted: [JSONValue] = outcome.converted.map { e in
                var o: [String: JSONValue] = [
                    "path": .string(e.candidate.rel),
                    "role": .string(e.candidate.defIDs.isEmpty ? "source" : "consolidated_wave"),
                ]
                if case .convert(let bits, let before, let after) = e.verdict {
                    o["bits"] = .int(bits)
                    o["bytes_before"] = .int(Int(before))
                    if let after { o["bytes_after"] = .int(Int(after)); o["flac"] = .string(e.candidate.destination.lastPathComponent) }
                }
                return .object(o)
            }
            let kept: [JSONValue] = outcome.kept.compactMap { e in
                guard case .keep(let reason) = e.verdict else { return nil }
                var o: [String: JSONValue] = ["path": .string(e.candidate.rel)]
                switch reason {
                case .readByConsolidatedContent: o["reason"] = .string("read_by_consolidated_content")
                case .araSource: o["reason"] = .string("ara_source")
                case .converter(let r):
                    switch r {
                    case .floatOverFullScale(let db):
                        o["reason"] = .string("float_over_full_scale"); o["peak_db"] = .number(db)
                    case .tooManyChannels(let n): o["reason"] = .string("too_many_channels"); o["channels"] = .int(n)
                    case .unsupportedDepth(let d): o["reason"] = .string("unsupported_depth"); o["detail"] = .string(d)
                    case .unreadable(let d): o["reason"] = .string("unreadable"); o["detail"] = .string(d)
                    case .empty: o["reason"] = .string("empty")
                    case .encodeFailed(let d): o["reason"] = .string("encode_failed"); o["detail"] = .string(d)
                    }
                }
                return .object(o)
            }
            return .object([
                "dry_run": .bool(dryRun),
                "converted": .array(converted),
                "kept": .array(kept),
                "count": .int(converted.count),
                "bytes_before": .int(Int(outcome.bytesBefore)),
                "bytes_after": .int(Int(outcome.bytesAfter)),
                "outside_count": .int(outcome.outside),
                "rebound": .int(outcome.rebound),
            ])
        }

        register("project.flac_progress",
                 summary: "Where the running `project.convert_to_flac` stands (what the clean-up popover's "
                        + "bar and the footer show): `running`, and `progress` {dry_run, done, total, "
                        + "current} or null. `last` is the final state of the last pass that ended "
                        + "(done == total), null before any. Read-only; poll it from ANOTHER connection "
                        + "while the conversion runs on the first.",
                 params: [], undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            @MainActor func json(_ p: FlacArchiveProgress?) -> JSONValue {
                guard let p else { return .null }
                return .object(["dry_run": .bool(p.dryRun), "done": .int(p.done), "total": .int(p.total),
                                "current": p.current.map { .string($0) } ?? .null])
            }
            return .object(["running": .bool(vm.isArchivingToFlac),
                            "progress": json(vm.flacArchiveProgress),
                            "last": json(vm.lastFlacArchiveProgress)])
        }
    }

    private static func diskScope(_ p: CommandParams) throws -> DiskCleanScope {
        let name = try p.string("scope", or: DiskCleanScope.session.rawValue)
        guard let scope = DiskCleanScope(rawValue: name) else {
            throw CommandError(code: .bad_params, message: "parameter 'scope': 'session' or 'folder' expected, got '\(name)'")
        }
        return scope
    }

    private static func candidateJSON(_ c: ProjectFileUsage.Candidate, usedBy: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "path": .string(c.id),
            "name": .string(c.name),
            "kind": .string(c.kind.rawValue),
            "folder": .string(c.folder),
            "size": .int(Int(c.size)),
            "files": .array(c.files.map { .string($0) }),
        ]
        if let usedBy, !usedBy.isEmpty { o["used_by"] = .array(usedBy.map { .string($0) }) }
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
            "cleanable_bytes": .int(Int((cleanable ?? []).reduce(Int64(0)) { $0 + $1.size })),
            "used_elsewhere_bytes": .int(Int(report.usedElsewhereBytes)),
            "protected_bytes": .int(Int(report.protectedBytes)),
            "cleanable": cleanable.map { list in
                .array(list.map { candidateJSON($0, usedBy: report.usedBy($0.id)) })
            } ?? .null,
            "used_elsewhere": .array(report.usedElsewhere.map { candidateJSON($0.candidate, usedBy: $0.usedBy) }),
            "protected": .array(report.protected.map { candidateJSON($0) }),
            "versions": .array(r.versionNames.map { .string($0) }),
            "unreadable_versions": .array(r.unreadableVersions.map { .string($0) }),
            "blocked": blocked.map { .string($0) } ?? .null,
            "computed_at": .number(r.computedAt.timeIntervalSince1970),
        ])
    }
}

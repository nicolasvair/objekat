import Foundation

// MARK: - The diagnostic journal family

/// `diag.*` : l'état du journal de diagnostic (@see Shared/DiagLog.swift), sa fin, un repère posé à la
/// main, et — en Debug seulement — de VRAIS crashs et une inondation de lignes pour le mesurer.
/// Rien ici n'alerte jamais : un crash est préparé en silence au relancement.
extension CommandRegistry {

    func registerDiagCommands() {

        register("diag.status",
                 summary: """
                 The diagnostic journal: `enabled`, the session file (`log`, `bytes`, `rotations`), the \
                 folder (`root`), and `last_crash` — the newest crash folder on disk (`dir`, `signal`, \
                 `summary`, `complete`), or null. Not itself journaled.
                 """,
                 undo: .none) { _ in
            let root = Diag.rootDirectory
            var payload: [String: JSONValue] = [
                "enabled": .bool(Diag.isEnabled),
                "root": .string(root.path),
                "pid": .int(Int(getpid())),
                "headless": .bool(Diag.isHeadless),
                "log": .stringOrNull(Diag.currentLogURL?.path),
                "bytes": .number(Double(objdiag_bytes_written())),
                "rotations": .int(Int(objdiag_rotation_count())),
            ]
            payload["last_crash"] = Self.jsonValue(DiagCrashReports.lastCrash(root: root)) ?? .null
            return .object(payload)
        }

        register("diag.tail",
                 summary: """
                 The last lines of THIS session's journal (the rotated file included), newest last. \
                 `since`: only the lines at or after that many seconds since the session start. Not \
                 itself journaled.
                 """,
                 params: [ParamSpec("lines", "int", required: false, "How many (default 50, at most 5000)."),
                          ParamSpec("since", "number", required: false,
                                    "Session seconds (the `+secs` column).")],
                 undo: .none) { p in
            guard let url = Diag.currentLogURL else {
                throw CommandError(code: .invalid_state, message: "diagnostic journal is off")
            }
            let count = min(max(try p.int("lines", or: 50), 1), 5000)
            let since = try p.optionalDouble("since")
            var lines: [String] = []
            for file in [URL(fileURLWithPath: url.path + ".1"), url] {
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true)
                        .map(String.init))
                }
            }
            if let since {
                lines = lines.filter { (DiagCrashReports.Builder.seconds(of: $0) ?? since) >= since }
            }
            return .object(["lines": .array(lines.suffix(count).map { .string($0) }),
                            "total": .int(lines.count)])
        }

        register("diag.mark",
                 summary: """
                 Reports a problem from a script: writes an ISSUE line, gathers `issues/<date>_<time>/` \
                 (note.txt, state.json, journal.log, oslog.txt), updates LATEST.md. Does not touch the \
                 clipboard. Works with the journal off too (the journal.log then says so).
                 """,
                 params: [ParamSpec("note", "string", required: false, "What went wrong.")],
                 undo: .none) { p in
            let note = try p.string("note", or: "")
            guard let folder = await DiagIssueReport.collect(note: note, copyToClipboard: false) else {
                throw CommandError(code: .engine_error, message: "could not create the issue folder")
            }
            return .object(["folder": .string(folder.path)])
        }

        register("diag.set_enabled",
                 summary: """
                 Turns the journal on or off for THIS session, at once. The saved preference is left \
                 alone unless `persist` is true (the menu's own switch).
                 """,
                 params: [ParamSpec("on", "bool", "Journal on or off."),
                          ParamSpec("persist", "bool", required: false,
                                    "Also write `pref.diagnosticLog` (default false).")],
                 undo: .none) { p in
            let on = try p.bool("on")
            if try p.bool("persist", or: false) {
                ObjekatPreferences.shared.diagnosticLog = on
            } else if on {
                Diag.start()
                if let vm = CommandContext.shared.viewModel {
                    Diag.setProject(name: vm.projectName, path: vm.projectURL?.path)
                }
            } else {
                Diag.stop(reason: "journal désactivé (diag.set_enabled)")
            }
            return .object(["enabled": .bool(Diag.isEnabled), "log": .stringOrNull(Diag.currentLogURL?.path)])
        }

        #if DEBUG
        register("debug.crash",
                 summary: """
                 DEBUG. Crashes the app FOR REAL, to test the crash path: `segv` (write at address 8), \
                 `abort`, `objc_exception` (uncaught NSException), `swift_fatal` (fatalError → SIGTRAP), \
                 `stack_overflow`. The connection drops, no answer comes. Produces a real .ips in \
                 ~/Library/Logs/DiagnosticReports: use sparingly.
                 """,
                 params: [ParamSpec("kind", "string",
                                    "segv | abort | objc_exception | swift_fatal | stack_overflow")],
                 undo: .none) { p in
            switch try p.string("kind") {
            case "segv":           objdiag_debug_crash(0)
            case "abort":          objdiag_debug_crash(1)
            case "stack_overflow": objdiag_debug_crash(2)
            case "objc_exception":
                NSException(name: NSExceptionName("OBJDiagTestException"),
                            reason: "debug.crash objc_exception", userInfo: nil).raise()
            case "swift_fatal":    fatalError("debug.crash swift_fatal")
            default:
                throw CommandError(code: .bad_params, message: "kind: segv|abort|objc_exception|swift_fatal|stack_overflow")
            }
            return .null   // never reached
        }

        register("debug.diag_flood",
                 summary: """
                 DEBUG. Writes `lines` journal lines (default 10000) and answers the cost of one call: \
                 `median_us`, `p95_us` and the file counters. The journal must be on.
                 """,
                 params: [ParamSpec("lines", "int", required: false, "Number of lines (default 10000)."),
                          ParamSpec("width", "int", required: false, "Characters per message (default 60).")],
                 undo: .none) { p in
            guard Diag.isEnabled else {
                throw CommandError(code: .invalid_state, message: "diagnostic journal is off")
            }
            let n = min(max(try p.int("lines", or: 10_000), 1), 5_000_000)
            let width = min(max(try p.int("width", or: 60), 1), 3500)
            let filler = String(repeating: "x", count: width)
            var samples = [Double](repeating: 0, count: n)
            for i in 0..<n {
                let t0 = DispatchTime.now().uptimeNanoseconds
                Diag.log(.api, "flood \(i) \(filler)")
                samples[i] = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1000.0
            }
            samples.sort()
            return .object([
                "lines": .int(n),
                "median_us": .number(samples[n / 2]),
                "p95_us": .number(samples[min(n - 1, n * 95 / 100)]),
                "bytes": .number(Double(objdiag_bytes_written())),
                "rotations": .int(Int(objdiag_rotation_count())),
            ])
        }
        #endif
    }

    /// `[String: Any]` (JSON read by Foundation) → `JSONValue`.
    private static func jsonValue(_ object: [String: Any]?) -> JSONValue? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value
    }
}

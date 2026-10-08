import Foundation
import CryptoKit
import Darwin

// MARK: - ARA source (Melodyne)
//
// An audio object can carry an ARA SOURCE: a Melodyne VST3 the clip plays through (docs/ara_melodyne_plan.md).
// It is added and removed through the plugin commands (`plugin.add` with an ARA plugin, `plugin.remove`
// on its id, `plugin.list` showing it first with `slot: "ara_source"`); this family only READS it and
// waits for its analysis. None of these commands opens an editor, and none is an edit.

extension CommandRegistry {

    func registerARACommands() {

        register("object.ara.status",
                 summary: """
                 The ARA source (Melodyne) of an audio object: `has_source`, `plugin` (the source, same \
                 payload as plugin.list), `engine_valid` (the live instance exists and works), \
                 `analysing`, `regions`, `archive_bytes` (the freshest archive known to the app) and \
                 `archive_stale` (a retouch or an end of analysis since the last capture), \
                 `model_archive_bytes` / `model_archive_sha1` (what a save would write right now) and \
                 `sync_failure` (the engine's reason when the source could not be set up). Reads only.
                 """,
                 params: [ParamSpec("id", "uuid", "Audio object.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            guard let source = object.araSource else {
                return .object(["id": .string(id.uuidString), "has_source": .bool(false)])
            }
            return .object(CommandAdapters.araStatus(source, objectID: id, in: vm))
        }

        register("object.ara.wait_analysis",
                 summary: """
                 Waits for Melodyne to finish analysing the object's audio (or for the archive restored \
                 at load to be in place). Answers like object.ara.status plus `waited_ms`. `timeout` \
                 (command error) after `timeout_ms` (default 120000). `invalid_state` when the object \
                 has no working source. The wait never blocks the app: the analysis runs meanwhile.
                 """,
                 params: [ParamSpec("id", "uuid", "Audio object."),
                          ParamSpec("timeout_ms", "int", required: false, "Waiting budget (default 120000).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let id = try p.uuid("id")
            let budget = Duration.milliseconds(max(0, try p.int("timeout_ms", or: 120_000)))
            guard vm.find(id: id)?.araSource != nil else {
                throw CommandError(code: .invalid_state, message: "the object has no ARA source")
            }
            let started = ContinuousClock.now
            while true {
                guard let source = vm.find(id: id)?.araSource else {
                    throw CommandError(code: .invalid_state, message: "the ARA source went away while waiting")
                }
                // A load still deferring the source (not set up yet) counts as "not ready".
                let st = engine.araStatus(forObjectID: id.uuidString)
                let valid = (st["valid"] as? NSNumber)?.boolValue ?? false
                let analysing = (st["analysing"] as? NSNumber)?.boolValue ?? false
                let regions = (st["regions"] as? NSNumber)?.intValue ?? 0
                if vm.araSyncFailures[id] != nil {
                    throw CommandError(code: .invalid_state,
                                       message: "the ARA source could not be set up: \(vm.araSyncFailures[id] ?? "")")
                }
                if valid && !analysing && regions >= 1 {
                    var out = CommandAdapters.araStatus(source, objectID: id, in: vm)
                    let ms = (ContinuousClock.now - started) / .milliseconds(1)
                    out["waited_ms"] = .number(Double(ms))
                    return .object(out)
                }
                guard ContinuousClock.now - started < budget else {
                    throw CommandError(code: .timeout, message: "the analysis did not finish in time",
                                       details: .object(["analysing": .bool(analysing), "valid": .bool(valid)]))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        register("object.ara.capture",
                 summary: """
                 Reads the ARA archive from the live Melodyne instance NOW (even if nothing is stale), \
                 stores it in the model (the project becomes modified if it changed) and answers \
                 `{bytes, ms, sha1, source_id, modification_id, stale_before}`. Not an edit: no undo \
                 point. `invalid_state` when the object has no working source.
                 """,
                 params: [ParamSpec("id", "uuid", "Audio object.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let id = try p.uuid("id")
            guard vm.find(id: id)?.araSource != nil else {
                throw CommandError(code: .invalid_state, message: "the object has no ARA source")
            }
            let staleBefore = engine.isARAArchiveStale(forObjectID: id.uuidString)
            guard let (archive, ms) = vm.forceCaptureARAArchive(for: id) else {
                throw CommandError(code: .invalid_state, message: "the ARA source is not running on this object")
            }
            return .object(["id": .string(id.uuidString),
                            "bytes": .int(archive.bytes), "ms": .number(ms),
                            "base64_chars": .int(archive.data.utf8.count),
                            "sha1": .string(CommandAdapters.sha1(archive.data)),
                            "source_id": .string(archive.sourceID),
                            "modification_id": .string(archive.modificationID),
                            "stale_before": .bool(staleBefore)])
        }

        register("object.ara.notes",
                 summary: """
                 The notes Melodyne analysed in the object, as the live instance reports them: \
                 `[{pitch, start, duration, velocity}]` (MIDI pitch, seconds from the start of the \
                 source). The witness that a retouch or an analysis survived a save, an undo or a copy. \
                 Reads only.
                 """,
                 params: [ParamSpec("id", "uuid", "Audio object.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let id = try p.uuid("id")
            guard vm.find(id: id)?.araSource != nil else {
                throw CommandError(code: .invalid_state, message: "the object has no ARA source")
            }
            let notes = JSONValue.fromFoundation(engine.araAnalysedNotes(forObjectID: id.uuidString))
            var count = 0
            if case .array(let a) = notes { count = a.count }
            return .object(["id": .string(id.uuidString), "count": .int(count), "notes": notes])
        }

        #if DEBUG
        register("debug.ara_report",
                 summary: """
                 DEBUG. ARA instances alive: `objects` (how many carry a source in the model), \
                 `instances` (running in the engine), `failed` (reason by object), `stale` (retouched \
                 since the last capture), the capture counters (`captures`, `capture_total_ms`, \
                 `last_capture_ms`, `last_capture_bytes`), `archive_bytes_total` (what the model holds) \
                 and `rss_mb`. For the cost measurements.
                 """,
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let objects = vm.araObjects()
            var running = 0, stale = 0, bytes = 0
            var failed: [String: JSONValue] = [:]
            for o in objects {
                bytes += o.araSource?.archive?.bytes ?? 0
                if let why = vm.araSyncFailures[o.id] { failed[o.id.uuidString] = .string(why); continue }
                if vm.araSynced.contains(o.id) {
                    let st = engine.araStatus(forObjectID: o.id.uuidString)
                    if (st["valid"] as? NSNumber)?.boolValue == true { running += 1 }
                    if engine.isARAArchiveStale(forObjectID: o.id.uuidString) { stale += 1 }
                }
            }
            let c = vm.araCaptureStats
            return .object(["objects": .int(objects.count), "instances": .int(running),
                            "failed": .object(failed), "stale": .int(stale),
                            "captures": .int(c.count), "capture_total_ms": .number(c.totalMs),
                            "last_capture_ms": .number(c.lastMs), "last_capture_bytes": .int(c.bytes),
                            "archive_bytes_total": .int(bytes),
                            "rss_mb": .number(CommandAdapters.residentMegabytes())])
        }

        register("debug.ara_mark_stale",
                 summary: """
                 DEBUG. Simulates a retouch for the cost measurements: marks the ARA sources of `ids` \
                 (default: every source of the project) as changed since their last capture, firing the \
                 same notification a real retouch fires. The next undo point then pays one capture each.
                 """,
                 params: [ParamSpec("ids", "array<uuid>", required: false, "Objects (default: all sources.)")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let ids = p.raw["ids"] != nil ? try p.uuids("ids") : vm.araObjects().map(\.id)
            engine.debugMarkARAStale(ids.map(\.uuidString))
            return .object(["marked": .int(ids.count)])
        }
        register("debug.ara_picker",
                 summary: "DEBUG: the ARA section of the \"+\" picker for an audio object, as the interface would compute it NOW, "
                        + "and optionally the click on one of its rows (exactly what the row does: addARASourceFromPicker). "
                        + "Returns {candidates:[{identifier,name,manufacturer}], refusal, has_source, disproved, picked?:{ok, refusal}}.",
                 params: [ParamSpec("host", "uuid", "the audio object the picker is opened on"),
                          ParamSpec("pick", "string", required: false, "identifier (bundle path) of the row to click, if offered"),
                          ParamSpec("search", "string", required: false, "the picker's search field")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let candidates = vm.araPickerCandidates(for: host, search: try p.string("search", or: ""))
            var out: [String: JSONValue] = [:]
            if let ident = try p.optionalString("pick") {
                // The row is only clickable when offered and not refused (`.disabled(refusal != nil)`).
                if let row = candidates.first(where: { $0.identifier == ident }) {
                    if let refusal = vm.araPickerRefusal(for: host) {
                        out["picked"] = .object(["ok": .bool(false), "refusal": .string(refusal.rawValue), "clickable": .bool(false)])
                    } else {
                        let refusal = vm.addARASourceFromPicker(objectID: host, available: row)
                        out["picked"] = .object(["ok": .bool(refusal == nil), "refusal": .stringOrNull(refusal?.rawValue), "clickable": .bool(true)])
                    }
                } else {
                    out["picked"] = .object(["ok": .bool(false), "refusal": .string("not_offered"), "clickable": .bool(false)])
                }
            }
            out["candidates"] = .array(vm.araPickerCandidates(for: host).map {
                .object(["identifier": .string($0.identifier), "name": .string($0.name), "manufacturer": .string($0.manufacturer)])
            })
            out["refusal"] = .stringOrNull(vm.araPickerRefusal(for: host)?.rawValue)
            out["has_source"] = .bool(vm.find(id: host)?.araSource != nil)
            out["disproved"] = .array(vm.araDisprovedIdentifiers.sorted().map { .string($0) })
            return .object(out)
        }
        #endif
    }
}

extension CommandAdapters {

    static func sha1(_ string: String) -> String {
        Insecure.SHA1.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Resident set size of this process, in MB (what Activity Monitor calls "Real Memory").
    static func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    /// The body of `object.ara.status` (also the end of `object.ara.wait_analysis`).
    static func araStatus(_ source: ARASource, objectID id: UUID, in vm: EditViewModel) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "id": .string(id.uuidString),
            "has_source": .bool(true),
            "plugin": araSourcePayload(source, objectID: id, in: vm),
            "model_archive_bytes": .int(source.archive?.bytes ?? 0),
            "model_archive_sha1": .stringOrNull(source.archive.map { sha1($0.data) }),
            "sync_failure": .stringOrNull(vm.araSyncFailures[id]),
        ]
        if let engine = vm.engine {
            let st = engine.araStatus(forObjectID: id.uuidString)
            out["engine_valid"] = .bool((st["valid"] as? NSNumber)?.boolValue ?? false)
            out["analysing"] = .bool((st["analysing"] as? NSNumber)?.boolValue ?? false)
            out["regions"] = .int((st["regions"] as? NSNumber)?.intValue ?? 0)
            out["mode"] = .string((st["mode"] as? String) ?? "none")
            out["archive_stale"] = .bool(engine.isARAArchiveStale(forObjectID: id.uuidString))
        }
        let known = vm.araArchiveCache[id] ?? source.archive
        out["archive_bytes"] = .int(known?.bytes ?? 0)
        return out
    }
}

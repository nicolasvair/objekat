import Foundation

// MARK: - What a canvas that `remember`s keeps besides its control values (plan §10, revision 4)

// A canvas opened with `remember` starts, next time, as the hand left it — LIVE, at every change, not
// only at Validate (a canvas's settings are tool preferences, not the answer to a form: Cancel and the
// window's ✕ keep them too). Its control values go through `ScriptPanelMemory` like a panel's. What a
// panel does not have is CANVAS-OWNED state — the mode (Instant / Selection) and the active tool —
// and that is what this file decides, as a pure rule with no model, no JSON and no window behind it
// (so it can be compiled alone and asserted: @see tools/test_script_canvas_memory.swift).
//
// The storage itself is `ScriptPanelMemory`'s (UserDefaults `scriptPanel.<key>.canvas`, ephemeral under
// `--no-recent` or `--headless`); the hand's Reset button does not touch it (it resets the CONTROLS).
//
// `nonisolated`: the project's default isolation is MainActor and this has no business there.

nonisolated struct CanvasRememberedState: Equatable, Sendable {
    /// `"instant"` or `"select"`; nil = nothing remembered.
    var mode: String?
    /// A tool id; nil = nothing remembered.
    var tool: String?

    static let modeNames: Set<String> = ["instant", "select"]

    /// What of a remembered state still fits the canvas being opened: a mode only if the canvas has
    /// modes and the name is one of the two; a tool only if the canvas declares a tool of that id. A
    /// script that changed its tools between two versions must not have a stale entry applied.
    static func restored(_ stored: CanvasRememberedState, modesEnabled: Bool,
                         toolIDs: [String]) -> CanvasRememberedState {
        var out = CanvasRememberedState(mode: nil, tool: nil)
        if modesEnabled, let m = stored.mode, modeNames.contains(m) { out.mode = m }
        if let t = stored.tool, toolIDs.contains(t) { out.tool = t }
        return out
    }
}

// MARK: - What a remembering canvas keeps IN THE PROJECT (revision 5)

// The two memories above are the USER's (UserDefaults: whatever project is open). Some settings belong
// to the PROJECT instead — the monitoring level of the editor is one: a quiet piece is heard at +6 dB,
// a loud one at -4, and reopening the editor in that project must find it so, while another project
// starts at 0 dB. They live in the project document (`ProjectDocument.canvasSettings`), keyed by the
// canvas's `remember` key (so a canvas that does not remember keeps nothing), and are written by the
// same document writer as the snap and the viewport (a save, a tab parked, "Save a copy"). Purely a
// listening preference: changing it never marks the project modified (like the viewport).
//
// This is the pure rule — which values are legal, what is worth writing — with no model behind it.

nonisolated struct CanvasProjectSettings: Codable, Equatable, Sendable {
    /// The monitoring level, dB. nil = never set (0 dB).
    var monitorDB: Double?

    init(monitorDB: Double? = nil) { self.monitorDB = monitorDB }

    private enum CodingKeys: String, CodingKey { case monitorDB }

    /// TOLERANT: a level of the wrong type (a hand-edited file) is ignored, never a reason for the whole
    /// project to refuse to open — it is a listening preference, not part of the sound.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monitorDB = (try? c.decodeIfPresent(Double.self, forKey: .monitorDB)) ?? nil
    }

    /// The range of the monitoring level, dB (listening only: never the validated result).
    static let monitorRange: ClosedRange<Double> = -20...20
    static let defaultMonitorDB = 0.0

    /// A level as the store keeps it: clamped to the range, and rounded to 0.1 dB (a slider's noise
    /// must not make a project file differ).
    static func clampedMonitor(_ db: Double) -> Double {
        let c = Swift.min(monitorRange.upperBound, Swift.max(monitorRange.lowerBound, db))
        return (c * 10).rounded() / 10
    }

    /// The level a canvas opens at: the project's, when it holds a finite one; else 0 dB.
    static func monitor(of stored: CanvasProjectSettings?) -> Double {
        guard let db = stored?.monitorDB, db.isFinite else { return defaultMonitorDB }
        return clampedMonitor(db)
    }

    /// The registry after `key`'s level became `db`: a level of 0 dB is the default and is not written (a
    /// project whose editor was never touched stays byte for byte as it was), and an empty entry goes.
    static func updating(_ all: [String: CanvasProjectSettings], key: String, monitorDB db: Double)
        -> [String: CanvasProjectSettings] {
        var out = all
        var entry = out[key] ?? CanvasProjectSettings()
        let v = clampedMonitor(db)
        entry.monitorDB = v == defaultMonitorDB ? nil : v
        if entry == CanvasProjectSettings() { out.removeValue(forKey: key) } else { out[key] = entry }
        return out
    }
}

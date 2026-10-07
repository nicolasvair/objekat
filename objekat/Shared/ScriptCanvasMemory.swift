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

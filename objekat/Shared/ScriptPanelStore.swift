import Foundation
import Observation

// MARK: - A window a script asks the app to show

// A script has no window of its own — it is a separate process — yet a detector with nine
// thresholds needs a place to put nine sliders, and a hand needs to see the result move while it
// drags one. So the script DECLARES a panel (checkboxes, sliders with their range, buttons) and
// the app draws it; the script reads what the hand did and answers by rewriting its overlay.
//
// The exchange is a LONG POLL, not a stream and not a 10 Hz sweep: the script keeps one
// `script.panel.wait` in flight and the app answers the instant `rev` moves. No wake-up while
// nothing changes, no polling loop in a process that also has to compute.
//
// `rev` moves ONLY when the hand does something (a value, a button, Validate, Cancel). What the
// script writes back (`status`, `busy`, recalibrated values) never moves it — otherwise the
// script's own update would wake its own next wait, for ever.
//
// Like the overlays, a panel belongs to the CONNECTION that opened it, is never persisted, and
// goes when that connection closes, when its object goes, or when another document is shown.

enum ScriptPanelState: String, Sendable {
    case open, validated, cancelled, closed
}

struct ScriptPanelControl: Equatable, Sendable {
    /// `progress` is a bar the SCRIPT drives (value 0…1, or `null` = indeterminate) and `section` a
    /// heading that groups the rows under it: neither holds anything a hand can set.
    enum Kind: String, Sendable { case bool, number, button, choice, progress, section }
    let id: String
    let kind: Kind
    /// The script may rewrite it (`script.panel.update`'s `labels`): a progress bar says WHAT is
    /// going on, and that changes from one stage to the next.
    var label: String
    let min: Double
    let max: Double
    let step: Double
    let unit: String
    /// The id of a bool control that greys this one when it is unchecked — "a box and a threshold".
    let enabledBy: String?
    /// A `choice`'s options, in the order the script gave them. Empty for every other kind.
    var options: [ScriptPanelOption] = []
    /// A `number`'s only possible values, in the order the script gave them (@see ScriptControlPresets):
    /// drawn as a row of buttons, and every value that comes in is snapped to the nearest. Empty = a slider.
    var presets: [Double] = []
    /// Drawn only once the hand has pressed the window's "Expert" button — the settings a first
    /// use never needs. Purely presentational: the value is still there, still read back in
    /// `values`, still remembered; a hidden control simply keeps whatever it holds.
    var advanced = false
}

/// One entry of a `choice`: a stable id (what the script reads back) and the label drawn.
extension ScriptPanelControl.Kind {
    /// What a HAND can set (`input`): a progress bar and a section are the script's own drawing.
    var holdsHandValue: Bool { self == .bool || self == .number || self == .choice }
    /// What the script can write with `update`'s `values`.
    var holdsValue: Bool { holdsHandValue || self == .progress }
}

struct ScriptPanelOption: Equatable, Sendable {
    let id: String
    let label: String
}

struct ScriptPanel: Equatable, Sendable {
    let id: UUID
    let owner: UUID
    let objectID: UUID?
    var title: String
    var controls: [ScriptPanelControl]
    /// bool → .bool, number → .number, choice → .string (the option's id), progress → .number 0…1 or
    /// .null (indeterminate). A button and a section hold no value.
    var values: [String: JSONValue]
    var rev: Int = 0
    var state: ScriptPanelState = .open
    /// Button ids pressed since the script last read, oldest first. Emptied by a read.
    var pendingEvents: [String] = []
    var status: String = ""
    var busy: Bool = false
    /// `remember`: the key under which Validate stores the hand's values (@see ScriptPanelMemory)
    /// and the app adds a Reset button. `declared` = what the script declared, which Reset returns to.
    var rememberKey: String? = nil
    var declared: [String: JSONValue] = [:]
}

@Observable final class ScriptPanelStore {

    private(set) var panels: [UUID: ScriptPanel] = [:]

    /// Set by the window layer (`ScriptPanelWindows`): called after a panel appears / after one
    /// stops being open. The store itself knows nothing about windows.
    @ObservationIgnored var panelOpened: ((UUID) -> Void)?
    @ObservationIgnored var panelEnded: ((UUID) -> Void)?

    /// The hand's slider moves at screen speed; the script needs the last value, not 120 of them
    /// a second. `rev` is bumped at most this often, with a trailing bump so the FINAL value is
    /// never left unannounced.
    static let coalesceInterval: TimeInterval = 1.0 / 30.0
    @ObservationIgnored private var lastBump: [UUID: Date] = [:]
    @ObservationIgnored private var trailing: Set<UUID> = []

    // MARK: Open / close

    /// One panel per connection: a second one replaces the first.
    func open(_ panel: ScriptPanel) {
        for old in panels.values where old.owner == panel.owner { remove(old.id, reason: .closed) }
        panels[panel.id] = panel
        panelOpened?(panel.id)
    }

    /// Ends a panel: `state` says how (closed by the script or by the app), and the record stays
    /// readable until its owner's connection goes, so a script can still be told `closed`.
    func end(_ id: UUID, as state: ScriptPanelState) {
        guard var p = panels[id], p.state == .open else { return }
        p.state = state
        p.rev += 1
        panels[id] = p
        panelEnded?(id)
    }

    private func remove(_ id: UUID, reason: ScriptPanelState) {
        end(id, as: reason)
        panels.removeValue(forKey: id)
    }

    func connectionClosed(_ owner: UUID) {
        for p in panels.values where p.owner == owner { remove(p.id, reason: .closed) }
    }

    func closeWhereObjectGone(exists: (UUID) -> Bool) {
        for p in panels.values where p.state == .open {
            if let o = p.objectID, !exists(o) { end(p.id, as: .closed) }
        }
    }

    func closeAll(reason: ScriptPanelState) {
        for p in panels.values { end(p.id, as: reason) }
    }

    // MARK: What the hand does

    /// Applies what a hand (the window, or `script.panel.input`) did. Unknown ids and kinds that do
    /// not match are refused; a number is clamped to its range. `coalesced`: a slider drag — the
    /// values land at once, the `rev` at most 30 times a second.
    func input(_ id: UUID, values: [String: JSONValue], press: String?, coalesced: Bool = false) throws {
        guard var p = panels[id] else {
            throw CommandError(code: .not_found, message: "no panel \(id.uuidString)")
        }
        guard p.state == .open else {
            throw CommandError(code: .invalid_state, message: "panel is \(p.state.rawValue)")
        }
        try ScriptControls.applyHand(values, controls: p.controls, into: &p.values)
        var immediate = !coalesced
        if let press {
            switch press {
            case "validate":
                p.state = .validated; immediate = true
                // Validate is the ONLY thing that remembers: not Cancel, not the window closing.
                if let key = p.rememberKey { ScriptControls.remember(key, controls: p.controls, values: p.values) }
            case "cancel":   p.state = .cancelled; immediate = true
            case "reset" where p.rememberKey != nil:
                // Back to what the script DECLARED; the script sees it as a hand's input (rev moves).
                ScriptControls.reset(p.rememberKey!, controls: p.controls, declared: p.declared,
                                     into: &p.values)
                immediate = true
            default:
                guard let c = p.controls.first(where: { $0.id == press }), c.kind == .button else {
                    throw CommandError(code: .bad_params, message: "no button '\(press)'")
                }
                p.pendingEvents.append(press)
                immediate = true
            }
        }
        panels[id] = p
        if immediate { bump(id) } else { bumpCoalesced(id) }
        if p.state != .open { panelEnded?(id) }
    }

    private func bump(_ id: UUID) {
        guard var p = panels[id] else { return }
        p.rev += 1
        panels[id] = p
        lastBump[id] = Date()
    }

    private func bumpCoalesced(_ id: UUID) {
        let since = Date().timeIntervalSince(lastBump[id] ?? .distantPast)
        if since >= Self.coalesceInterval { bump(id); return }
        guard !trailing.contains(id) else { return }
        trailing.insert(id)
        let wait = Self.coalesceInterval - since
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 1))
            guard let self else { return }
            self.trailing.remove(id)
            self.bump(id)
        }
    }

    // MARK: What the script writes back — never moves `rev`

    func update(_ id: UUID, status: String?, busy: Bool?, values: [String: JSONValue],
                labels: [String: String] = [:]) throws {
        guard var p = panels[id] else {
            throw CommandError(code: .not_found, message: "no panel \(id.uuidString)")
        }
        if let status { p.status = status }
        if let busy { p.busy = busy }
        try ScriptControls.applyLabels(labels, to: &p.controls)
        try ScriptControls.applyScript(values, controls: p.controls, into: &p.values)
        panels[id] = p
    }

    /// The answer of `script.panel.get` / `wait`: reading drains the button events.
    func read(_ id: UUID) throws -> ScriptPanel {
        guard var p = panels[id] else {
            throw CommandError(code: .not_found, message: "no panel \(id.uuidString)")
        }
        let snapshot = p
        if !p.pendingEvents.isEmpty { p.pendingEvents = []; panels[id] = p }
        return snapshot
    }
}

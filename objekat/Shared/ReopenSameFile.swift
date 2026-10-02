import Foundation

/// Opening a file a tab ALREADY holds — the decision, with nothing behind it (no model, no
/// engine, no tab), which is why it can be compiled and asserted alone
/// (`tools/test_reopen_same_file.swift`), like `CutSelection` / `TabReorder` before it.
///
/// What it answers to: re-opening the project one is working on is how one goes BACK to the
/// state of the last save after a mistake. So it RELOADS the file from disk into the tab that
/// holds it (never a second tab, never a no-op), after the same Save / Don't Save / Cancel
/// question a close or a quit asks when there are unsaved changes.
///
/// The rules, in the order they are applied:
/// 1. a blocking operation (`EditViewModel.tabSwitchBlocker`: a load, a direct export, a render, a
///    consolidated object open for editing) refuses — a reload tears the document down exactly as
///    a tab switch does, so it is refused for exactly the same reasons, and refused, not queued;
/// 2. a CLEAN tab reloads straight away, with no question: what is on screen is what is on disk,
///    so nothing a hand made is lost — only the undo history and the selection go, as with any
///    opening. A confirmation there would be a dialogue asking about nothing;
/// 3. a MODIFIED tab: a hand is asked (the close/quit question, its own title); a script, which
///    cannot answer a modal, must say `discard` explicitly — `tab.close`'s contract — and is
///    refused otherwise.
enum ReopenSameFile {

    /// Who is asking: a hand (a menu, the Finder, a recent project) can answer a dialogue; a
    /// script cannot, and says up front whether unsaved changes may go.
    enum Requester: Equatable {
        case hand
        case script(discard: Bool)
    }

    enum Decision: Equatable {
        /// Refused for a blocking operation — the associated i18n key is `tabSwitchBlocker`'s.
        case refuse(reasonKey: String)
        /// Reload from disk now, nothing to ask.
        case reload
        /// Ask Save / Don't Save / Cancel, then reload unless cancelled.
        case askThenReload
        /// A script asked to reload a modified tab without `discard`.
        case refuseDirty
    }

    static func decide(blocker: String?, isDirty: Bool, requester: Requester) -> Decision {
        if let blocker { return .refuse(reasonKey: blocker) }
        guard isDirty else { return .reload }
        switch requester {
        case .hand:                 return .askThenReload
        case .script(let discard):  return discard ? .reload : .refuseDirty
        }
    }

    /// The reload refusal's own wording, derived from a `tabSwitchBlocker` key: the reasons are the
    /// same, the sentence is not ("can't switch tabs" would be wrong over a reload of the tab in
    /// front). An unknown key falls back on a generic sentence rather than on nothing. Literal
    /// keys on both sides, never a concatenation: `xcstrings.py orphans` finds a key by its text.
    static func reloadRefusalKey(forBlocker blocker: String) -> String {
        refusalKeys[blocker] ?? "project.reload.refused.busy"
    }

    private static let refusalKeys: [String: String] = [
        "tabs.switch.refused.loading": "project.reload.refused.loading",
        "tabs.switch.refused.export": "project.reload.refused.export",
        "tabs.switch.refused.render": "project.reload.refused.render",
        "tabs.switch.refused.consolidateEdit": "project.reload.refused.consolidateEdit",
    ]
}

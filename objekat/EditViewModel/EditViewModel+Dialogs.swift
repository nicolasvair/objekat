import AppKit

// MARK: - Dialogue policy

/// What the view-model does when it has to ASK A QUESTION or REPORT something.
///
/// An `NSAlert.runModal()` blocks the main loop until the click. From the interface that is
/// exactly what we want; from a script there is nobody to click, and the app freezes for good.
/// Hence an explicit policy, carried by the session and read at every dialogue, rather than a
/// "script mode" boolean scattered through the calls.
/// The raw values ARE the API's contract (`app.set_dialog_policy`): writing them here rather
/// than translating them on the fly guarantees that the command which sets the policy and the
/// one which reads it back speak the same vocabulary.
enum DialogPolicy: String, Sendable {
    /// The historical behaviour, and the default: the modal shows, the user decides.
    case ask
    /// Answer "yes / continue / open anyway" without showing anything.
    case assumeYes = "assume_yes"
    /// Answer "no / cancel" without showing anything.
    case assumeNo = "assume_no"
}

/// The trace of a dialogue the policy settled without showing it.
///
/// WHY KEEP A JOURNAL — without it, removing the modals just replaces a freeze with a silence,
/// which is barely better: the script carries on without knowing it was told "missing plugins"
/// or "render failed". The journal makes those messages readable after the fact.
struct DialogRecord: Sendable {
    let title: String
    let info: String
    /// What the policy answered in the user's place ("reported", "yes", "no"…).
    let answer: String
    let at: Date
}

/// The answer to the "project modified" guard — three outcomes, not two.
enum DirtyDecision: Sendable {
    case save
    case discard
    case cancel
}

extension EditViewModel {

    // MARK: - Journal

    /// Bounded: a long driving session must not swell memory with messages nobody will read
    /// again.
    private static let maxDialogRecords = 100

    func recordDialog(_ title: String, _ info: String, answer: String) {
        dialogJournal.append(DialogRecord(title: title, info: info, answer: answer, at: Date()))
        if dialogJournal.count > Self.maxDialogRecords {
            dialogJournal.removeFirst(dialogJournal.count - Self.maxDialogRecords)
        }
        NSLog("[DIALOGUE] %@ — %@ (answer: %@)", title, info, answer)
    }

    func clearDialogJournal() { dialogJournal = [] }

    // MARK: - Report (no question)

    /// A message with no decision: an "OK" to click, or nothing to do depending on the policy.
    /// Both automatic policies behave the same — there is no choice to make, only a message not
    /// to lose.
    func notify(_ title: String, _ info: String, style: NSAlert.Style = .warning) {
        guard dialogPolicy == .ask else {
            recordDialog(title, info, answer: "reported")
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = style
        alert.runModal()
    }

    // MARK: - Ask (yes / no)

    /// A binary question. `yes` is the left-hand button (the one `assumeYes` picks).
    func confirm(_ title: String,
                 _ info: String,
                 yes: String,
                 no: String,
                 style: NSAlert.Style = .warning) -> Bool {
        switch dialogPolicy {
        // The journal records a STABLE token and not the button's title: the titles are
        // localised, and `app.dialogs` is a machine contract — a script must not have to know
        // which language the machine that hosts it is running in.
        case .assumeYes:
            recordDialog(title, info, answer: "yes")
            return true
        case .assumeNo:
            recordDialog(title, info, answer: "no")
            return false
        case .ask:
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = info
            alert.alertStyle = style
            alert.addButton(withTitle: yes)
            alert.addButton(withTitle: no)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    // MARK: - Ask (save / don't save / cancel)

    /// The "project modified" guard. `assumeYes` means CARRY ON WITHOUT SAVING, and not "save":
    /// a script that asks to continue wants to move on, and triggering a write it did not ask
    /// for would be the opposite of predictable driving. The explicit path already exists for
    /// anyone who wants the other meaning (`save`, then the operation).
    func askDirtyDecision(titleKey: String) -> DirtyDecision {
        let title = L(titleKey)
        let info = L("dialog.dirty.info", projectName)
        switch dialogPolicy {
        case .assumeYes:
            recordDialog(title, info, answer: "don't save")
            return .discard
        case .assumeNo:
            recordDialog(title, info, answer: "cancel")
            return .cancel
        case .ask:
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = info
            alert.addButton(withTitle: L("dialog.dirty.save"))
            alert.addButton(withTitle: L("dialog.dirty.discard"))
            alert.addButton(withTitle: L("common.cancel"))
            alert.alertStyle = .warning
            switch alert.runModal() {
            case .alertFirstButtonReturn:  return .save
            case .alertSecondButtonReturn: return .discard
            default:                       return .cancel
            }
        }
    }

    // MARK: - Ask (a choice from a list)

    /// A choice among several titles. Returns the chosen index, or `nil` if cancelled.
    /// `assumeYes` takes the FIRST — the callers' order is meaningful (the toolbar's order, Main
    /// at the head), so the first is the least surprising default.
    func choose(_ title: String,
                _ info: String,
                options: [String],
                confirmTitle: String,
                cancelTitle: String = L("common.cancel")) -> Int? {
        guard !options.isEmpty else { return nil }
        switch dialogPolicy {
        case .assumeYes:
            recordDialog(title, info, answer: options[0])
            return 0
        case .assumeNo:
            recordDialog(title, info, answer: "cancel")
            return nil
        case .ask:
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 25),
                                      pullsDown: false)
            for option in options { popup.addItem(withTitle: option) }
            popup.selectItem(at: 0)

            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = info
            alert.alertStyle = .informational
            alert.accessoryView = popup
            alert.addButton(withTitle: confirmTitle)
            alert.addButton(withTitle: cancelTitle)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return popup.indexOfSelectedItem.clamped(to: 0...(options.count - 1))
        }
    }
}

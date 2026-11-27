import AppKit

// MARK: - What ⌘Z / ⌘X / ⌘C / ⌘V / ⌘A do, for the keyboard AND the Edit menu

/// ONE definition of the edit shortcuts, read by two doors: the timeline's key monitor
/// (@see TimelineKeyHandler) and the Edit menu's entries (@see objekatApp). The monitor sees a key
/// first and consumes it, so the menu's own key equivalent only fires when the monitor let the key
/// through — that is, while text is being typed, where the menu hands the standard selector to the
/// responder chain instead (a field keeps its own copy, paste and undo).
extension EditViewModel {

    /// Text is being typed somewhere in the app — a field of ours, a system panel (out of process),
    /// or a JUCE plugin's own text box. The same three worlds as `TimelineView.isTextInputActive`.
    var textInputHasKeyboard: Bool {
        guard let key = NSApp.keyWindow else { return engine?.isEditingTextInPluginEditor() ?? false }
        if key.firstResponder is NSTextView { return true }
        if TimelineView.isSystemPanelKey(key) { return true }
        return engine?.isEditingTextInPluginEditor() ?? false
    }

    /// A menu entry: the responder chain's selector while text is typed, otherwise the project's action.
    func performEditMenu(_ selector: Selector, _ action: () -> Void) {
        if textInputHasKeyboard { NSApp.sendAction(selector, to: nil, from: nil) } else { action() }
    }

    /// ⌘Z / ⇧⌘Z. An open consolidated object: ⌘Z cancels the opening (a clean rollback of the preview
    /// machinery plus popping the session), like Esc — the generic ⌘Z would restore the items without
    /// undoing the session. While a recording runs the stack is not ours to move: the recording's own
    /// bookkeeping (@see `RecordingMuteLog.undoDepthAfterPush`) counts on it, so ⌘Z only beeps.
    func performUndoShortcut(redo: Bool) {
        guard !isRecording else { NSSound.beep(); return }
        if !redo, isEditingConsolidate { cancelConsolidateEdit() }
        else if redo { self.redo() }
        else { undo() }
    }

    /// ⌘A. The Inputs tab's list when it holds the keyboard (@see KeyboardClaim); the piano-roll context:
    /// every note of the focused clip; else every object.
    func performSelectAllShortcut() {
        // A list that holds the keyboard and selects its own rows (the Inputs tab) takes it first.
        if KeyboardClaim.shared.performSelectAll() { return }
        if let cid = focusedMidiClipID, let clip = find(id: cid), clip.showsPianoRollInline {
            selectedMidiNoteIDs = Set(clip.midiNotes.map(\.id))
        } else {
            selectAll()
        }
    }

    /// Which surface an edit shortcut ended up acting on — what `edit.copy` / `edit.cut` / `edit.paste`
    /// answer, so a script can assert that the key went where the hand meant it to.
    enum EditShortcutBranch: String {
        /// The signal view's chain fragment.
        case plugins
        /// The signal view's send cards (⌘C, ⌘V; ⌘X is a dead key there).
        case sends
        /// A passage of automation, on the zone or the loose points selected.
        case automation
        /// A passage of automation laid at the CARET of a band (⌘V only).
        case automationCaret
        /// The piano roll's notes.
        case midiNotes
        /// The time selection's objects.
        case timeSelection
        /// The selected objects, or the clipboard's objects.
        case objects
        /// Nothing to act on.
        case none
    }

    /// ⌘X.
    @discardableResult
    func performCutShortcut() -> EditShortcutBranch {
        // The send cards hold the keyboard and are deleted, never moved: ⌘X is a dead key there, and not a
        // cut of the OBJECT the hand is plainly not pointing at.
        if sendSurfaceHasKeyboard {
            return .none
        }
        sendClipboardIsLive = false
        if automationSurfaceHasKeyboard {
            cutAutomationSelection()       // the automation band (internal undo push)
            return .automation
        } else if !selectedMidiNoteIDs.isEmpty {
            cutSelectedMidiNotes()         // the piano-roll context (internal undo push)
            return .midiNotes
        } else if timeSelection != nil {
            edit { cutTimeSelection() }
            return .timeSelection
        } else if !selectedIDs.isEmpty {
            edit { cutSelected() }
            return .objects
        }
        return .none
    }

    /// ⌘C.
    @discardableResult
    func performCopyShortcut() -> EditShortcutBranch {
        // The send cards of the signal view (exclusive with the plugin cards).
        if sendSurfaceHasKeyboard {
            copySelectedSends()                // nothing chosen: the clipboard is left as it was
            return .sends
        }
        sendClipboardIsLive = false
        if pluginSurfaceHasKeyboard {
            copySelectedPluginsToClipboard()   // the signal view
            return .plugins
        } else if automationSurfaceHasKeyboard {
            copyAutomationSelection()          // the automation band
            return .automation
        } else if !selectedMidiNoteIDs.isEmpty {
            copySelectedMidiNotes()            // the piano-roll context
            return .midiNotes
        } else if timeSelection != nil {
            copyTimeSelection()
            return .timeSelection
        } else if !selectedIDs.isEmpty {
            copySelected()
            return .objects
        }
        return .none
    }

    /// ⌘V.
    @discardableResult
    func performPasteShortcut() -> EditShortcutBranch {
        // The send cards hold the keyboard: the sends copied go onto the objects selected (the one the signal
        // view shows, which is the whole selection while it shows anything).
        if sendSurfaceHasKeyboard, sendClipboard != nil {
            pasteSendsOntoSelection()          // internal undo push
            return .sends
        }
        // The sends are the LAST thing copied and objects are selected in the timeline (several, perhaps:
        // the signal view shows none then): ⌘V lays the sends on all of them. Not with the Send tool, whose
        // ⌘V stays the objects' paste, and not over a surface that holds the keyboard for another paste.
        if sendClipboardIsLive, sendClipboard != nil, !selectedIDs.isEmpty, activeTool != .toolAux,
           selectedPluginHostID == nil, !automationSurfaceHasKeyboard, !pasteGoesToMidiNotes,
           timeSelection == nil {
            pasteSendsOntoSelection()          // internal undo push
            return .sends
        }
        // The signal view holds the keyboard ⇒ the chain fragment goes into ITS chain, after the last
        // selected card or at the end when none is chosen.
        if let host = selectedPluginHostID, !pluginClipboard.isEmpty {
            pastePlugins(into: host)           // internal undo push
            return .plugins
        }
        // A passage of automation goes back into the band it was traced on — the zone says which rows
        // and at which instant (@see pasteAutomation).
        if automationSurfaceHasKeyboard, canPasteAutomation {
            pasteAutomation()                  // internal undo push
            return .automation
        }
        // The notes take priority in the piano-roll context: notes selected, or a piano roll that holds
        // the keyboard (a click on its background, a cut that emptied the selection) with notes to
        // paste. They land in THAT piano roll, at the caret (@see pasteGoesToMidiNotes).
        if pasteGoesToMidiNotes {
            pasteMidiNotes()                   // internal undo push
            return .midiNotes
        }
        // A click in a band leaves a caret and nothing traced: with a passage of automation copied,
        // that is a place to lay it, and it wins over the objects' paste, which would land the
        // clipboard's objects on the band's lane instead (@see automationTarget, `forPaste`).
        if canPasteAutomationAtCaret {
            pasteAutomation()                  // internal undo push
            return .automationCaret
        }
        edit { paste() }
        return .objects
    }
}

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
    /// undoing the session.
    func performUndoShortcut(redo: Bool) {
        if !redo, isEditingConsolidate { cancelConsolidateEdit() }
        else if redo { self.redo() }
        else { undo() }
    }

    /// ⌘A. The piano-roll context: every note of the focused clip.
    func performSelectAllShortcut() {
        if let cid = focusedMidiClipID, let clip = find(id: cid), clip.showsPianoRollInline {
            selectedMidiNoteIDs = Set(clip.midiNotes.map(\.id))
        } else {
            selectAll()
        }
    }

    /// ⌘X.
    func performCutShortcut() {
        if automationSurfaceHasKeyboard {
            cutAutomationSelection()       // the automation band (internal undo push)
        } else if !selectedMidiNoteIDs.isEmpty {
            cutSelectedMidiNotes()         // the piano-roll context (internal undo push)
        } else if timeSelection != nil {
            edit { cutTimeSelection() }
        } else if !selectedIDs.isEmpty {
            edit { cutSelected() }
        }
    }

    /// ⌘C.
    func performCopyShortcut() {
        if pluginSurfaceHasKeyboard {
            copySelectedPluginsToClipboard()   // the signal view
        } else if automationSurfaceHasKeyboard {
            copyAutomationSelection()          // the automation band
        } else if !selectedMidiNoteIDs.isEmpty {
            copySelectedMidiNotes()            // the piano-roll context
        } else if timeSelection != nil {
            copyTimeSelection()
        } else if !selectedIDs.isEmpty {
            copySelected()
        }
    }

    /// ⌘V.
    func performPasteShortcut() {
        // The signal view holds the keyboard ⇒ the chain fragment goes into ITS chain, after the last
        // selected card or at the end when none is chosen.
        if let host = selectedPluginHostID, !pluginClipboard.isEmpty {
            pastePlugins(into: host)           // internal undo push
        }
        // A passage of automation goes back into the band it was traced on — the zone says which rows
        // and at which instant (@see pasteAutomation).
        else if automationSurfaceHasKeyboard, canPasteAutomation {
            pasteAutomation()                  // internal undo push
        }
        // The notes take priority in the piano-roll context (notes selected).
        else if !selectedMidiNoteIDs.isEmpty, canPasteMidiNotes {
            pasteMidiNotes()                   // internal undo push
        } else {
            edit { paste() }
        }
    }
}

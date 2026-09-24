import Foundation

/// Multi-project tabs (INC 1) — ONE engine, ONE view-model, several project documents taking
/// turns being "the one in front". See `project_multi_project_tabs_plan` (memory): the design
/// deliberately rules out a per-tab engine (`OBJEngineCore`'s callbacks are
/// `__unsafe_unretained`, so a second instance — or destroying/recreating the one there is — is
/// off the table). A tab switch is therefore PARK the current document (capture everything that
/// is not already inside `ProjectDocument`, tear the engine's state down) then RESTORE the target
/// one through the very same `applyProjectDocumentAsync` a project opening uses, only
/// non-cancellable (@see `ProjectLoadState.cancellable`).

/// Everything a parked (inactive) tab needs to come back exactly as it was left — the document
/// itself PLUS the pieces of state that live outside `ProjectDocument` (undo history, the
/// selection, the transport's stopped position, the per-tab view). Captured by `parkProject()`,
/// consumed once by `restoreParkedProject(_:)`.
struct ParkedProject {
    var doc: ProjectDocument
    var projectURL: URL?
    var projectName: String
    var isDirty: Bool

    var undoStack: [EditSnapshot]
    var redoStack: [EditSnapshot]

    var selectedIDs: Set<UUID>
    var cursorPosition: Double
    var caretLane: Int?
    var timeSelection: TimeSelection?
    var loopModeEnabled: Bool
    var loopRegion: ClosedRange<Double>?
    var viewport: ViewportState
}

extension EditViewModel {

    // MARK: - Blocking a switch

    /// nil = free to switch. Otherwise an i18n key naming what is still running — read by
    /// `Workspace.select`/`newTab`/`close` BEFORE anything is touched, so a switch either goes
    /// through whole or not at all (never half-parked). The list mirrors `Quiescence.inFlight()`
    /// (CommandAPI/Quiescence.swift), which is the authority on "is the model still working" — kept
    /// as a separate, UI-facing check (an i18n key rather than a free-text reason) since a tab
    /// switch is refused with a message in the tab bar, not diagnosed like `wait_idle`.
    var tabSwitchBlocker: String? {
        if isLoadingProject { return "tabs.switch.refused.loading" }
        if exportJob?.isRunning == true { return "tabs.switch.refused.export" }
        if !bakingIDs.isEmpty || !recomputingConsolidateIDs.isEmpty || isCascadingRebake {
            return "tabs.switch.refused.render"
        }
        if isEditingConsolidate || !consolidateEditStack.isEmpty {
            return "tabs.switch.refused.consolidateEdit"
        }
        return nil
    }

    // MARK: - Plugin editors

    /// Closes every open plugin editor — native (a JUCE window) or built-in (an `NSWindow` of
    /// ours) — before the engine underneath them is torn down for a tab switch. Reaches the
    /// objects' plugins (`allPluginRefs()`, already flattened through parallel racks) AND the
    /// stems' bus chains (INC 2, not covered by `allPluginRefs()`, @see `Stem.plugins`), because a
    /// bus's FX editor is exactly as capable of outliving the engine state it points at as an
    /// object's.
    func closeAllPluginEditors() {
        for ref in allPluginRefs() {
            if isPluginEditorOpen(plug: ref.plugin) { closePluginEditor(plug: ref.plugin) }
        }
        for stem in stems {
            for plug in Self.flattenLeaves(stem.plugins) {
                if isPluginEditorOpen(plug: plug) { closePluginEditor(plug: plug) }
            }
        }
    }

    // MARK: - Park / restore

    /// Captures everything the ACTIVE project needs to come back as it stands right now — called
    /// right before the engine is handed a different document. Plugin states are refreshed from
    /// the engine first (`itemsWithCapturedPluginStates`/`stemsWithCapturedPluginStates`), exactly
    /// as a save would, so a knob turned live is not lost the moment the tab leaves the screen.
    func parkProject() -> ParkedProject {
        let doc = projectDocument(items: itemsWithCapturedPluginStates(),
                                  consolidateDefinitions: Array(consolidateDefinitions.values))
        var parkedDoc = doc
        parkedDoc.stems = stemsWithCapturedPluginStates()
        return ParkedProject(doc: parkedDoc,
                             projectURL: projectURL,
                             projectName: projectName,
                             isDirty: isDirty,
                             undoStack: undoStack,
                             redoStack: redoStack,
                             selectedIDs: selectedIDs,
                             cursorPosition: cursorPosition,
                             caretLane: caretLane,
                             timeSelection: timeSelection,
                             loopModeEnabled: loopModeEnabled,
                             loopRegion: loopRegion,
                             viewport: currentViewport)
    }

    /// Brings a parked tab back to the front: loads its document through the SAME door a project
    /// opening uses (`applyProjectDocumentAsync`), non-cancellable — a tab switch is not a choice
    /// the user backs out of mid-flight the way an "Open…" is — then restores everything
    /// `ProjectDocument` does not carry.
    ///
    /// ORDER, and it is not arbitrary: the undo/redo stacks are restored AFTER the load
    /// (`performTeardown` empties them as part of any load, this one included), and `isDirty` is
    /// restored LAST (some of what the load touches on its way, through `didSet`s meant for a
    /// freshly opened file, can leave its own opinion on `isDirty` — the parked value must win).
    func restoreParkedProject(_ parked: ParkedProject) async {
        _ = await applyProjectDocumentAsync(parked.doc, displayName: parked.projectName,
                                            cancellable: false, preservingClipboard: true)

        projectURL = parked.projectURL
        projectName = parked.projectName

        undoStack = parked.undoStack
        redoStack = parked.redoStack

        selectedIDs = parked.selectedIDs
        cursorPosition = parked.cursorPosition
        caretLane = parked.caretLane
        timeSelection = parked.timeSelection
        loopModeEnabled = parked.loopModeEnabled
        loopRegion = parked.loopRegion
        // Consumed by the timeline on its next appearance/layout pass, exactly as a project
        // opening's own restore does — @see `pendingViewRestore`.
        pendingViewRestore = parked.viewport

        // Selections and transient UI states that belong to the OBJECTS just replaced: holding
        // onto a plugin selection, a crossfade pair or a rename field from the tab just left would
        // point at IDs that (may) no longer resolve to anything in the new document.
        selectedPluginIDs = []
        selectedPluginHostID = nil
        selectedCrossfade = nil
        renamingID = nil
        pluginParamValues = [:]
        liveAutomationValues = [:]
        KeyboardClaim.shared.revoke()

        isDirty = parked.isDirty
    }
}

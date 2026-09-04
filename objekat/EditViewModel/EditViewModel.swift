import Foundation
import AppKit
import AVFoundation
import Accelerate
import UniformTypeIdentifiers
import Observation
import SwiftUI

/// Times an interface gesture, separating the two costs that always get confused: the
/// MUTATION of the model, and the frame it triggers. The second time is a PROXY — it runs
/// until the next turn of the main thread's loop, where the SwiftUI re-evaluation has
/// normally taken place; it does not tell layout, rendering and compositing apart. Silent under 1 ms.
///
/// It is this separation that cleared SwiftUI over the opening of a sound object (model
/// 3019 ms against 481 ms of frame, the model being on its own an AU instantiation). To be
/// reused before accusing the view: the reflex is expensive when it is wrong.
@MainActor
enum UIPerf {
    static func measure(_ label: String, _ body: () -> Void) {
        let t0 = CFAbsoluteTimeGetCurrent()
        body()
        measureFrom(t0, label)
    }

    /// The variant for a gesture that cannot be wrapped in a block (guards, early returns):
    /// `t0` is taken by hand at the first useful point.
    static func measureFrom(_ t0: CFAbsoluteTime, _ label: String) {
        let modelMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        DispatchQueue.main.async {
            let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            if totalMs >= 1 {
                NSLog("[PERF] %@: model %.0f ms, frame %.0f ms", label, modelMs, totalMs - modelMs)
            }
        }
    }
}

@MainActor
@Observable
final class EditViewModel {
    var items: [SoundObject] = [] {
        didSet {
            if laneEntriesRebuildDepth == 0 { rebuildLaneEntries() }
        }
    }
    var selectedIDs: Set<UUID> = []
    /// The MIDI notes selected in the open piano rolls (ids of `MidiNote`, unique across every
    /// clip). Independent of `selectedIDs` (which carries the clips/groups).
    var selectedMidiNoteIDs: Set<UUID> = []
    /// The last MIDI clip whose piano roll received a click: the current "piano-roll context".
    /// Lets ⌘A select every note of that clip even with no note selection
    /// active. Reset to nil as soon as a click lands elsewhere in the timeline. Pure UI.
    var focusedMidiClipID: UUID? = nil
    /// The objects whose BAKE (a background render) is UNDER WAY: a soft lock. The sub-tree
    /// stays live and playable, but creating/opening/detaching/dissolving is blocked while
    /// the render runs. Emptied in the render's completion. See EditViewModel+Bake.
    var bakingIDs: Set<UUID> = []
    /// The dialogue policy: what the view-model does when it has to ask a question or
    /// report something. `.ask` (the default) = the historical behaviour, the modal shows.
    /// External driving switches it for the length of a command. See EditViewModel+Dialogs.
    var dialogPolicy: DialogPolicy = .ask
    /// What the policy settled without showing it — otherwise removing the modals would come to
    /// replacing a freeze with a silence. Bounded, purgeable. See EditViewModel+Dialogs.
    var dialogJournal: [DialogRecord] = []
    /// The project's sound-object registry: an instance (`SoundObject.definitionID`)
    /// resolves its content through this UID. See EditViewModel+Objects.
    var objectDefinitions: [UUID: ObjectDefinition] = [:]
    /// The definitions whose AUTOMATIC re-bake (a transitive cascade after a dependency has
    /// changed) is UNDER WAY in the background. Drives a "recomputing" indicator on their
    /// instances, replacing the manual "Refresh" action. See
    /// EditViewModel+Objects (`cascadeRebakeStaleFixpoint`).
    var recomputingDefinitionIDs: Set<UUID> = []
    /// The definitions one of whose instances has just been RESYNCHRONISED (a re-bake finished: a
    /// transitive cascade or a closing propagated to the other instances). Drives a transient ✓
    /// (~15 s) on their instances, taking over from the recomputing spinner. See
    /// EditViewModel+Objects (`markDefinitionResynced`).
    var recentlyResyncedDefinitionIDs: Set<UUID> = []
    /// The ✓'s clearing deadline per definition: guarantees a full duration even if several
    /// re-bakes overlap (each marking pushes the deadline back; the clearing only happens
    /// if the current deadline is reached). See `markDefinitionResynced`.
    @ObservationIgnored var resyncedBadgeDeadline: [UUID: Date] = [:]
    /// The stack of NESTED sound-object openings: opening a sound object B located INSIDE a
    /// sound object A already open stacks a child session on the parent. The top = the "current"
    /// session (the one closing/cancelling resolves, whose content is materialised
    /// and watched). Empty = no object open. See EditViewModel+Objects.
    var objectEditStack: [ObjectEditSession] = []

    /// The definition/instance of the CURRENT session (the top of the stack), or nil if no object is
    /// open — they drive the closing/cancelling UI and the mirror indicator.
    var editingDefinitionID: UUID? { objectEditStack.last?.defID }
    var editingPlacementID: UUID? { objectEditStack.last?.placementID }
    /// A snapshot of the EXACT instance before materialisation (the current session) — restored as it is by
    /// `cancelObjectEdit`, independently of the other edits made in the meantime elsewhere
    /// in the project (unlike a generic undo).
    var editingOriginalPlacement: SoundObject? {
        get { objectEditStack.last?.originalPlacement }
        set { if !objectEditStack.isEmpty { objectEditStack[objectEditStack.count - 1].originalPlacement = newValue } }
    }

    // MARK: A sound object's live mirror
    //
    // A CLOSED sound object is baked: all of its instances read one wave. OPEN it is LIVE:
    // the content is materialised on the instance opened and the OTHERS become mirrors of it,
    // put back in their own place — they all refer to the same origin, with no render at all.
    // Every mutation of the sub-tree being edited (structure, fades, gain, speed, plugins, live knob
    // params) arms the debounced re-mirroring. See EditViewModel+Objects
    // (`scheduleLiveMirror`). The driving state is below (@ObservationIgnored: purely
    // mechanical, it must not invalidate the views).

    /// True when at least one other instance follows the open object live — drives the indicator
    /// carried by the origin.
    var hasLiveMirrors: Bool { !(objectEditStack.last?.mirrorSnapshots.isEmpty ?? true) }
    /// The pending debounce before laying the mirrors again.
    @ObservationIgnored var liveMirrorWorkItem: DispatchWorkItem? = nil
    /// Suspends the arming of the re-mirroring (a session opening, a closing/cancel under way).
    @ObservationIgnored var liveMirrorSuppressed: Bool = false
    /// True while a transitive re-bake cascade is running (a re-entrance guard). See
    /// EditViewModel+Objects (`cascadeRebakeStaleFixpoint`).
    @ObservationIgnored var isCascadingRebake: Bool = false
    /// The definitions whose re-bake FAILED during the current cascade: excluded from the selection
    /// so as not to pick them again in a loop (they stay out of date). Reset at every
    /// new cascade.
    @ObservationIgnored var cascadeFailedDefs: Set<UUID> = []
    /// The number of re-bakes done in the current cascade: a safety ceiling against loops
    /// (abnormal cyclic dependencies). Reset at every new cascade.
    @ObservationIgnored var cascadeRebakeCount: Int = 0
    var renamingID: UUID? = nil
    var activeTool: ActiveTool = .toolSelection
    var isToolPermanent: Bool = true
    var heldToolKeyCode: UInt16? = nil
    /// The target stem (a 1-based index: 1 = Main, 2 = the 2nd stem…) when `activeTool == .toolStemAssign`.
    /// The mode arms by holding a digit, or locks with ⇧ (`isToolPermanent`),
    /// exactly like C/V/P/S. Drives the assignment on click, the Enter commit and the HUD.
    var stemAssignIndex: Int? = nil
    /// The send brought forward by the Send tool (a drag/hover on a knob) — drives the visual accent.
    var sendToolFocus: SendFocus? = nil
    /// The cheatsheet shown (a tool key or a modifier held ~0.6 s); nil = hidden.
    /// See ShortcutCheatsheet / CheatsheetHold.
    var cheatsheet: CheatsheetContext? = nil
    var stems: [Stem] = [Stem(id: UUID(), name: "Main", colorIndex: 0, format: .stereo)]

    var mainStemID: UUID { stems.first?.id ?? UUID() }

    // MARK: - Solo at the clip level (see EditViewModel+Solo)
    //
    // Session state (not persisted, outside undo, like the bus mute): the engine having no
    // notion of solo, it is emulated by pushing -96 dB onto the inaudible leaves.

    /// The objects soloed "one by one" (a confirmed "solo on" attribute).
    var soloedIDs: Set<UUID> = []
    /// The stems soloed wholesale (the s + N shortcut, combinable).
    var soloedStemIDs: Set<UUID> = []
    /// The roots of the TEMPORARY solo (tied to a ⇧+space playback, or to "s" held); nil otherwise.
    var tempSoloRoots: Set<UUID>? = nil
    /// True when the current temporary solo comes from the "s" key being HELD (and not from an
    /// audition): drives its HUD, which invites you to release the key to go back to normal listening.
    var heldSoloActive: Bool = false
    /// True while "s" is physically held down (set/lifted by the keyboard monitor). Opens the
    /// "click = enter/leave the listening" mode in the timeline — independent of `heldSoloActive`,
    /// which assumes a layer already armed (hence a selection at the moment of the "s").
    var soloKeyHeld: Bool = false
    /// The cached set of the objects currently audible (leaves + ancestor groups) — drives the
    /// dimming. Rebuilt by `refreshSolo` (EditViewModel+Solo) at every change of solo.
    var soloAudibleObjectIDs: Set<UUID> = []
    /// The listening state frozen into values (solo + bus mutes), the single source of the silence rule.
    /// Rebuilt by `refreshAudibility` (EditViewModel+Audibility); readable from a context
    /// not MainActor-isolated, which a call to the view model would not be.
    var audibility = AudibilitySnapshot()

    var engine: OBJEngineCore? = nil {
        didSet {
            guard engine != nil else { return }
            loadCachedPlugins()
            engine?.setTempo(tempo)
            engine?.setTimeSig(timeSigNumerator, denominator: timeSigDenominator)
            // INC 2: declares the Main bus as the FX chain host (master) for the new session.
            engine?.setMasterStemKey(mainStemID.uuidString)
            engine?.onEditorVisibilityChanged = { [weak self] key, isOpen in
                let id = UUID(uuidString: key)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if isOpen { self.openEditorPluginID = id }
                    else if self.openEditorPluginID == id { self.openEditorPluginID = nil }
                    // An editor window that closes by itself (the ✕ button) goes back through
                    // no Swift call: it is here, and nowhere else, that the parameter-touch
                    // listening is given back (@see EditViewModel+AutomationTargets).
                    if let id, !isOpen { self.endPluginParamTouchWatch(id) }
                }
            }
            // A knob turned in the native GUI of an AU/VST does not cross the model: this is the
            // only path by which it becomes its object's "automation to come" row.
            // The VALUE travels with the touch: the engine has it to hand at that instant, and
            // it is the only way of showing it live without questioning the plugin on every
            // render frame (@see pluginParamValues).
            engine?.onPluginParamTouched = { [weak self] key, paramID, value in
                guard let pluginKey = UUID(uuidString: key) else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pluginParamValues[.plugin(pluginKey: pluginKey, paramID: paramID)] =
                        value.clamped(to: 0...1)
                    self.recordPluginParamTouch(pluginKey: pluginKey, paramID: paramID)
                }
            }
        }
    }

    /// The plugin whose editor is currently open (a native one through the engine, or a built-in through
    /// its own NSWindow). Drives the link overlay in the timeline (lines + highlighting).
    var openEditorPluginID: UUID? = nil

    /// The editor windows open for Tracktion built-in plugins, by plugin id.
    /// The counterpart of `_editorWindows` on the JUCE side (@see openBuiltInPluginEditor).
    var builtInEditorWindows: [UUID: BuiltInPluginEditorWindowController] = [:]

    /// The names and ranges of the automatable parameters, by plugin (@see pluginParamInfos). A PURE cache:
    /// outside observation, because it fills lazily FROM the rendering — an automation
    /// band drawing a plugin parameter's row asks for its name in the middle of `body`.
    /// Observing it would have the view invalidated by its own read.
    @ObservationIgnored var pluginParamInfoCache: [UUID: [String: PluginParamInfo]] = [:]

    /// A plugin parameter's last KNOWN value, normalised 0…1 (the model's convention,
    /// @see ParamRef.valueRange). Fed by the bridge at every touch while an editor is
    /// open, and by a one-off read when the automation band needs a value
    /// it has never seen (@see EditViewModel.automationDisplayValue).
    ///
    /// OBSERVED, unlike `pluginParamInfoCache`: it is a value that MOVES, and the "automation
    /// to come" row must follow the knob being turned. It is never written from
    /// a render — only from the bridge or an `onChange` — so no invalidation loop.
    var pluginParamValues: [ParamRef: Float] = [:]

    /// What the CURVES of the selected objects are worth at the playback position — the value
    /// the engine is playing right now, per object then per parameter. Refreshed by the playhead
    /// tick (@see refreshLiveAutomation) and read by the inspector: an automated fader has to
    /// move before your eyes, otherwise the figure shown lies throughout the playback.
    ///
    /// Bounded to the SELECTION, the only thing the inspector shows: computing it for the whole
    /// project would cost twenty times a second what nobody is looking at.
    var liveAutomationValues: [UUID: [ParamRef: Float]] = [:]

    /// The PLUGIN PARAMETER curves already pushed to the engine, per object. A session memory, outside
    /// observation: it serves only to know what to ERASE when a row disappears from the model
    /// (@see pushAutomation, which explains why those targets are not swept on every
    /// push the way the fader or the sends are).
    @ObservationIgnored var pushedPluginParams: [UUID: Set<ParamRef>] = [:]

    /// The position (in timeline canvas coords) of the "link" indicator during a plugin drag
    /// with ⌘ held. nil otherwise. Updated live by the timeline's DropDelegate.
    var pluginLinkDropLocation: CGPoint? = nil

    // MARK: - Dropping several files (banner + mode)

    /// How to lay down several files dropped at once onto the timeline.
    /// It is the ONLY choice the gesture leaves, and it bears only on the layout: the files
    /// all arrive, whatever the mode (before, only the last survived — they were all
    /// laid at the same instant on the same lane and chased one another away through `resolveOverlaps`).
    enum FileDropMode: Equatable {
        /// The default: the same starting instant, one lane each. It is the layout that preserves
        /// the time relationship of several takes of one scene (they start together).
        case stacked
        /// ⌘: a single lane, end to end in the order of the selection.
        case sequential

        var title: String { self == .stacked ? L("drop.mode.stacked") : L("drop.mode.sequential") }
        var detail: String {
            self == .stacked
                ? L("drop.mode.stacked.detail")
                : L("drop.mode.sequential.detail")
        }
    }

    /// A hovered file, as the preview knows it: its name and its duration. The duration stays
    /// `nil` for as long as it takes to read it (an asynchronous file read) — the preview rectangle then
    /// takes a waiting width rather than showing nothing.
    struct FileDropPreview: Equatable {
        var name: String
        var duration: Double?
    }

    /// The waiting width, in seconds, of a rectangle whose duration has not been read yet.
    static let fileDropPlaceholderDuration: Double = 4.0

    /// A file's place in the batch: its lane and its instant. Produced by `fileDropLayout`.
    struct FileDropSlot: Equatable, Identifiable {
        var index: Int
        var startTime: Double
        var duration: Double
        var lane: Int
        var id: Int { index }
    }

    /// The batch's layout, in the order of the selection. Shared by the real placement and by
    /// the ghost preview of the hover: the two MUST say the same thing, otherwise the drop belies
    /// what was shown a second earlier.
    static func fileDropLayout(durations: [Double], mode: FileDropMode,
                               baseLane: Int, baseStart: Double) -> [FileDropSlot] {
        var cursor = baseStart
        return durations.enumerated().map { index, duration in
            let slot: FileDropSlot
            switch mode {
            case .stacked:
                // Stacked: the same start, one lane each — the time relationship between the
                // files is preserved, as is the case for takes of one scene.
                slot = FileDropSlot(index: index, startTime: baseStart,
                                    duration: duration, lane: baseLane + index)
            case .sequential:
                // End to end: a single lane, one after another. The cursor advances by the duration
                // WANTED, not by the one that will survive `resolveOverlaps` — otherwise a clip already
                // in place would shift all the rest of the batch.
                slot = FileDropSlot(index: index, startTime: cursor,
                                    duration: duration, lane: baseLane)
            }
            cursor += duration
            return slot
        }
    }

    /// A file drag under way over the timeline (nil otherwise): feeds the explanatory banner
    /// at the bottom, the ghost preview on the lanes, and decides the layout at the drop.
    struct FileDropHint: Equatable {
        var count: Int
        var mode: FileDropMode
        /// The cursor's position in the timeline canvas — it is what lays the
        /// preview rectangles. nil until a hover update has arrived.
        var location: CGPoint? = nil
        /// The batch's files, in the order of the selection. Empty until the providers are
        /// resolved: the rectangles are then drawn at the waiting width.
        var previews: [FileDropPreview] = []

        /// The durations to draw: the real one as soon as it is known, the waiting one otherwise. Always
        /// `count` values, so that the rectangles appear as soon as the hover begins.
        var previewDurations: [Double] {
            (0..<max(count, 0)).map { i in
                (i < previews.count ? previews[i].duration : nil)
                    ?? EditViewModel.fileDropPlaceholderDuration
            }
        }
    }

    var fileDropHint: FileDropHint? = nil

    /// Reads the drop mode from the current state of the modifiers. ⌘ = end to end.
    static func fileDropMode(for flags: NSEvent.ModifierFlags) -> FileDropMode {
        flags.contains(.command) ? .sequential : .stacked
    }

    /// A probe that follows ⌘ during the hover. `dropUpdated` is only called on a MOUSE
    /// MOVE: without it, pressing ⌘ without moving would change nothing on screen — yet that is
    /// exactly the expected gesture (you arrive over the timeline, you read the banner, you
    /// press ⌘). An ordinary `Timer` would not do: the drag loop runs in
    /// `NSEventTrackingRunLoopMode`, where a timer in `.default` mode never fires; the
    /// resumptions of `Task.sleep`, on the other hand, go through the main queue, served in every mode.
    @ObservationIgnored private var fileDropModifierWatch: Task<Void, Never>? = nil

    /// Opens (or updates) the banner for `count` files and arms the ⌘ tracking.
    /// `location` is the cursor's position in the canvas: it lays the ghost preview.
    func beginFileDropHint(count: Int, location: CGPoint) {
        // An update IN PLACE rather than a replacement: `dropUpdated` calls this method again on
        // every mouse move, and starting from a fresh hint would throw away the previews already
        // resolved (their durations) at every pixel travelled.
        var hint = fileDropHint ?? FileDropHint(count: count, mode: .stacked)
        hint.count    = count
        hint.mode     = Self.fileDropMode(for: NSEvent.modifierFlags)
        hint.location = location
        // Reassigned only if it changes: rewriting the same value would invalidate the view for nothing.
        if fileDropHint != hint { fileDropHint = hint }
        guard fileDropModifierWatch == nil else { return }
        fileDropModifierWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard let self, self.fileDropHint != nil else { return }
                let m = Self.fileDropMode(for: NSEvent.modifierFlags)
                if self.fileDropHint?.mode != m { self.fileDropHint?.mode = m }
            }
        }
    }

    /// The mode kept for the drop under way (`stacked` by default outside a hover).
    var fileDropMode: FileDropMode { fileDropHint?.mode ?? .stacked }

    /// True once per hover only. Resolving the previews costs one file read
    /// per element: it is armed on entry, not on every mouse move.
    @ObservationIgnored private var fileDropPreviewClaimed = false

    func claimFileDropPreviewLoad() -> Bool {
        guard !fileDropPreviewClaimed else { return false }
        fileDropPreviewClaimed = true
        return true
    }

    /// Fills in the names and durations of the hovered files (ignored if the hover has ended in the
    /// meantime — the rectangles no longer have any reason to be).
    func setFileDropPreviews(_ previews: [FileDropPreview]) {
        guard fileDropHint != nil else { return }
        fileDropHint?.previews = previews
    }

    /// Closes the banner and disarms the tracking (leaving the hover, the drop done, or a cancel).
    func endFileDropHint() {
        fileDropModifierWatch?.cancel()
        fileDropModifierWatch = nil
        fileDropPreviewClaimed = false
        fileDropHint = nil
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var timeSelection: TimeSelection? = nil

    var loopModeEnabled: Bool = false
    var loopRegion: ClosedRange<Double>? = nil

    func toggleLoopMode() {
        if loopModeEnabled { loopModeEnabled = false; return }
        if let ts = timeSelection {
            loopRegion = ts.timeRange
        } else if !selectedIDs.isEmpty {
            // A RECURSIVE search: the selection may bear on a clip or a group nested
            // inside a group (the startTimes are absolute at any depth).
            let selected = selectedIDs.compactMap { find(id: $0) }
            let lo = selected.map(\.startTime).min() ?? 0
            let hi = selected.map { $0.startTime + $0.duration }.max() ?? lo
            if hi > lo { loopRegion = lo...hi }
        }
        guard loopRegion != nil else { return }
        loopModeEnabled = true
    }

    /// ⌘L: sets the TRANSPORT's loop region on the selection and arms the loop. Not a
    /// toggle — the gesture is "loop THAT", and doing it again on another selection must
    /// move the region again, not turn the loop off (that is the transport bar's
    /// button, `toggleLoopMode`). With nothing selected, it leaves everything as it is.
    func setLoopRegionFromSelection() {
        var region: ClosedRange<Double>? = nil
        if let ts = timeSelection {
            region = ts.timeRange
        } else if !selectedIDs.isEmpty {
            // A RECURSIVE search, like `toggleLoopMode`: the startTimes are absolute at any
            // depth of nesting.
            let selected = selectedIDs.compactMap { find(id: $0) }
            let lo = selected.map(\.startTime).min() ?? 0
            let hi = selected.map { $0.startTime + $0.duration }.max() ?? lo
            if hi > lo { region = lo...hi }
        }
        guard let region else { return }
        loopRegion = region
        loopModeEnabled = true
    }

    // MARK: - Export (the File ▸ Export… window)
    //
    // The render runs in the background in the engine: the window closes as soon as it starts
    // and the app stays usable. What follows is only the visible state — the settings being
    // edited, the live job, the progress timer. The machinery is in EditViewModel+Export.

    /// The export window open (a modal sheet of ContentView).
    var exportPanelPresented: Bool = false
    /// The settings being edited in the window, remade at every opening
    /// (`makeExportSettings`) from the project and the last format choices kept.
    var exportSettings = ExportSettings()
    /// The export under way, or finished a short while ago (the progress banner shows it for a few
    /// seconds before it disappears). nil = nothing to show.
    var exportJob: ExportJob? = nil
    /// The timer reading the engine's progress during the render phase.
    @ObservationIgnored var exportProgressTimer: Timer? = nil
    /// The cancel flag consulted by the MP3 encoder, which runs on a background queue: it cannot
    /// read the view-model's state (isolated to the main actor), hence this locked box.
    @ObservationIgnored var exportCancelFlag: ExportCancelFlag? = nil
    /// The deferred clearing of the banner after an export has finished.
    @ObservationIgnored var exportStatusClearWork: DispatchWorkItem? = nil

    /// The time range the timeline must REVEAL (zoom + scroll to show it in
    /// full), laid down by the export window when the I/O markers are set. The TimelineView
    /// applies it then sets it back to nil — the same protocol as `pendingViewRestore`.
    var pendingRangeReveal: ClosedRange<Double>? = nil

    /// A request to STOP playback issued by the model: an export in direct render takes the Edit
    /// out of the device manager for the length of the render, and the view's transport state (which lives in
    /// ContentView) has to know, otherwise the button stays on "stop" and the playhead freezes
    /// while claiming to play. The view applies it then sets it back to false — the same protocol as
    /// `pendingRangeReveal`.
    var pendingPlaybackStop: Bool = false

    var filterText: String = ""
    var pixelsPerSecond: Double = 100
    var blockHeight: Double = 121.5
    var waveformDisplayDB: Double = 0

    // MARK: - The timeline's visible area (persisted with the project)
    //
    // The scroll position lives in the TimelineView (ScrollPosition); it is copied here
    // at every change so that it can be saved. `@ObservationIgnored`: a plain scroll
    // must invalidate no view.

    @ObservationIgnored var viewScrollX: Double = 0
    @ObservationIgnored var viewScrollY: Double = 0

    /// The view to restore after loading a project — the TimelineView observes it, applies the
    /// scroll then sets it back to nil. nil = nothing to restore.
    var pendingViewRestore: ViewportState? = nil

    /// Incremented when `items` has just been REPLACED wholesale (a new project, an opening) and not
    /// simply edited. The TimelineView uses it to rearm the length of its canvas on the
    /// real content: without this signal, a short project opened after a long one kept the length of the
    /// previous one (the "sticky" mechanism that protects editing gestures has no reason to
    /// apply from one project to another). Neither `projectURL` nor `items` is enough: the URL changes
    /// before the content is in place, and a project can be reopened on the same URL.
    var projectLoadToken: Int = 0

    /// A snapshot of the current view, written into the project document.
    var currentViewport: ViewportState {
        ViewportState(pixelsPerSecond: pixelsPerSecond, blockHeight: blockHeight,
                      scrollX: viewScrollX, scrollY: viewScrollY)
    }

    /// True during an `applySnapshot` (undo/redo) or the application of a project document:
    /// the tempo and time signature are then RESTORED data, not user actions.
    /// They are pushed to the engine WITH NO remap (the restored model is already the authority on the positions)
    /// and without marking the project modified.
    @ObservationIgnored var isRestoringTransport = false

    /// Changes the tempo as a user ACTION: undoable (the snapshot captures the old
    /// tempo, since `pushUndo` precedes the write) and marks the project modified. Every
    /// UI entry point (the BPM field, the ↑/↓ arrows) goes through here; writing to
    /// `tempo` directly stays reserved for loading and for restoring a snapshot.
    func applyTempo(_ bpm: Double) {
        let clamped = max(20, min(300, bpm))
        guard clamped != tempo else { return }
        pushUndo()
        tempo = clamped
    }

    /// The same for the time signature (undoable + marks it modified).
    func applyTimeSig(numerator: Int, denominator: Int) {
        guard numerator != timeSigNumerator || denominator != timeSigDenominator else { return }
        pushUndo()
        timeSigNumerator   = numerator
        timeSigDenominator = denominator
    }

    var tempo: Double = 120.0 {
        didSet {
            guard tempo != oldValue else { return }
            // A restoration (undo / opening a project): no remap, no "modified".
            guard !isRestoringTransport else {
                engine?.setTempo(tempo, remap: false)
                return
            }
            isDirty = true
            let remap = gridMode == .bpm
            engine?.setTempo(tempo, remap: remap)
            guard remap else {
                // Time mode: the positions do not move, but the musical (MIDI) content does.
                rescaleMidiClipDurations(ratio: oldValue / tempo)
                return
            }
            let ratio = oldValue / tempo
            if let lr = loopRegion, ratio.isFinite, ratio > 0, ratio != 1.0 {
                loopRegion = (lr.lowerBound * ratio)...(lr.upperBound * ratio)
            }
            if let ts = timeSelection, ratio.isFinite, ratio > 0, ratio != 1.0 {
                let lo = ts.timeRange.lowerBound * ratio
                let hi = ts.timeRange.upperBound * ratio
                if hi > lo { timeSelection = TimeSelection(timeRange: lo...hi, lanes: ts.lanes) }
            }
            resyncPositionsFromTracktion(remapRatio: ratio)
        }
    }
    var timeSigNumerator: Int = 4 {
        didSet {
            engine?.setTimeSig(timeSigNumerator, denominator: timeSigDenominator)
            if timeSigNumerator != oldValue && !isRestoringTransport { isDirty = true }
        }
    }
    var timeSigDenominator: Int = 4 {
        didSet {
            engine?.setTimeSig(timeSigNumerator, denominator: timeSigDenominator)
            if timeSigDenominator != oldValue && !isRestoringTransport { isDirty = true }
        }
    }

    @ObservationIgnored var applyHorizontalZoom: ((Double) -> Void)?
    @ObservationIgnored var applyVerticalZoom: ((Double) -> Void)?
    @ObservationIgnored var beginHorizontalZoomDrag: (() -> Void)?
    @ObservationIgnored var endHorizontalZoomDrag: (() -> Void)?
    @ObservationIgnored var beginVerticalZoomDrag: (() -> Void)?
    @ObservationIgnored var endVerticalZoomDrag: (() -> Void)?

    enum SortKey: String, CaseIterable {
        case startTime = "time"
        case duration  = "duration"
        case lane      = "lane"
    }
    var sortKey: SortKey = .startTime
    var sortAscending: Bool = true

    var clipboard: ClipboardContent? = nil
    /// A clipboard dedicated to MIDI notes (independent of `clipboard`, which carries clips/groups).
    /// See EditViewModel+MIDINotes.
    var midiNotesClipboard: MidiNotesClipboard? = nil
    /// The visible pitch window (the bottom pitch) of each piano roll, by MIDI clip id. nil ⇒
    /// the default window (C3=48 → C5). Adjusted by the octave shift so as to "follow" the notes.
    /// Pure UI, not persisted (reopening the project starts again from the default window).
    var pianoRollBasePitchByClip: [UUID: Int] = [:]

    /// The height (in px) of a note row in the piano rolls, set by the zoom +/- at the bottom of the
    /// piano roll. GLOBAL (shared by every clip). Decoupled from the vertical zoom (blockHeight):
    /// shift+R/T enlarges the band → more rows visible, the height per note stays fixed.
    /// Pure UI, not persisted. See `pianoRollZoom`.
    var pianoRollRowHeight: Double = 10

    /// The per-clip "crop" mode: shows only the rows of the pitches actually present in the
    /// clip (skipping the unused pitches). The note height is unchanged. Pure UI, not persisted.
    var pianoRollCropByClip: [UUID: Bool] = [:]
    /// The scroll offset (an index into the sorted list of the pitches in use) in crop mode, per
    /// clip. Driven by oct +/- when crop is active. Bounded on reading. Pure UI, not persisted.
    var pianoRollCropOffsetByClip: [UUID: Int] = [:]

    var seekRequest: Double? = nil
    var cursorPosition: Double = 0
    var caretLane: Int? = nil   // the display lane of the last click; nil = no caret

    // The clips flattened with absolute positions (for the list and certain operations)
    var allClips: [SoundObject] {
        var result: [SoundObject] = []
        func collect(_ arr: [SoundObject], laneOffset: Int) {
            for item in arr {
                switch item.kind {
                case .clip, .aux, .midiClip:
                    var abs = item
                    abs.lane += laneOffset
                    result.append(abs)
                case .group(let children, _):
                    collect(children, laneOffset: item.lane + laneOffset)
                }
            }
        }
        collect(items, laneOffset: 0)
        return result
    }

    /// The flattening of the objects into display rows. CACHED: rebuilt only
    /// when `items` changes (didSet), not on every access. Read in ~64 sites (including per
    /// drag/scroll frame) → the cache removes an O(N²) repeated on the main thread.
    private(set) var laneEntries: [LaneEntry] = []
    private var laneEntriesRebuildDepth = 0

    func rebuildLaneEntries() {
        laneEntries = Self.buildLaneEntries(items, parentID: nil, depth: 0, displayLaneOffset: 0)
    }

    /// Grouped mutations of `items`: a single rebuild of laneEntries at the end instead
    /// of one per write. ⚠️ DO NOT read `laneEntries` inside (the cache is frozen until
    /// it returns). Re-entrant (depth).
    func batchItemsMutation(_ body: () -> Void) {
        beginCoalescedItemsMutation()
        defer { endCoalescedItemsMutation() }
        body()
    }

    /// The same bounds as `batchItemsMutation`, but OPEN: indispensable when the sequence to
    /// cover is asynchronous (a batch of API commands), which a synchronous closure cannot
    /// express. Every `begin` must have its `end`, otherwise the lane cache stays
    /// frozen for good.
    func beginCoalescedItemsMutation() {
        laneEntriesRebuildDepth += 1
    }

    func endCoalescedItemsMutation() {
        laneEntriesRebuildDepth -= 1
        if laneEntriesRebuildDepth == 0 { rebuildLaneEntries() }
    }

    private static func buildLaneEntries(
        _ items: [SoundObject],
        parentID: UUID?,
        depth: Int,
        displayLaneOffset: Int
    ) -> [LaneEntry] {
        // The prefix sum of expandedSpan by lane → extraAbove in O(N) instead of O(N²).
        // prefixBelowLane[L] = Σ expandedSpan of the items of a lane strictly < L (identical
        // to the old `items.filter { $0.lane < item.lane }.reduce(...)`).
        var spanByLane: [Int: Int] = [:]
        for it in items { spanByLane[it.lane, default: 0] += it.expandedSpan }
        var prefixBelowLane: [Int: Int] = [:]
        var running = 0
        for lane in spanByLane.keys.sorted() {
            prefixBelowLane[lane] = running
            running += spanByLane[lane]!
        }

        var result: [LaneEntry] = []
        result.reserveCapacity(items.count)
        for item in items {
            let extraAbove = prefixBelowLane[item.lane] ?? 0
            let dl = displayLaneOffset + item.lane + extraAbove

            result.append(LaneEntry(
                displayLane: dl,
                item:        item,
                absStart:    item.startTime,
                depth:       depth,
                parentID:    parentID
            ))

            // `showsChildrenInline` and not `isExpanded`: a group in automation mode keeps
            // its unfolding but its band shows curves, not its children. Not emitting them
            // here removes them at a stroke from ALL the geometry — rendering, hover, tap, drag,
            // keyboard, cut — which resolves on `laneEntries`.
            if item.showsChildrenInline, case .group(let children, _) = item.kind {
                result += buildLaneEntries(
                    children,
                    parentID:          item.id,
                    depth:             depth + 1,
                    displayLaneOffset: dl + 1
                )
            }
        }
        return result.sorted { $0.displayLane < $1.displayLane }
    }

    var filteredObjects: [SoundObject] {
        let clips = allClips
        let base = filterText.isEmpty ? clips
            : clips.filter { $0.displayName.localizedCaseInsensitiveContains(filterText) }
        return base.sorted { a, b in
            let less: Bool
            switch sortKey {
            case .startTime: less = a.startTime < b.startTime
            case .duration:  less = a.duration  < b.duration
            case .lane:      less = a.lane       < b.lane
            }
            return sortAscending ? less : !less
        }
    }

    var snapEnabled: Bool = true
    var cmdKeyHeld: Bool = false
    var effectiveSnapEnabled: Bool { snapEnabled != cmdKeyHeld }
    /// ⌥ held at this instant. The counterpart of `cmdKeyHeld` above, and for the same reason:
    /// a drag under way only re-reads the modifiers on each frame, hence never while
    /// the mouse does not move. Pressing ⌥ WITHOUT moving did not switch the move to
    /// a copy — the gesture seemed deaf. The `flagsChanged` monitor feeds this flag, and the
    /// timeline follows it (@see TimelineView.onChange).
    var optKeyHeld: Bool = false
    // The grid mode is saved in the document → changing it modifies the project.
    // (Restored by the loading, which sets `isDirty = false` again just afterwards.)
    var gridMode: GridMode = .time {
        didSet { if gridMode != oldValue { isDirty = true } }
    }
    var objectSnapGuide: Double? = nil
 
    var gridLevels: [GridLevel] {
        if gridMode == .bpm {
            let spb      = 60.0 / max(1.0, tempo)
            let spBar    = spb * Double(timeSigNumerator)
            let bpx      = spb * pixelsPerSecond
            let barPx    = spBar * pixelsPerSecond
            let showBeat = bpx > bpmGridThresholdPx
            // The bar is no longer the widest marker: when it falls below the threshold,
            // the anchor rises by itself to 4, 8, 16… bars (see BarLadder). At the current zoom
            // anchor = major = 1 bar → strictly the earlier behaviour.
            let anchor = BarLadder.anchor(barWidthPx: barPx, minPx: bpmGridThresholdPx)
            let major  = BarLadder.anchor(barWidthPx: barPx, minPx: gridMajorThresholdPx)

            var levels: [GridLevel] = []
            if major > anchor {
                levels.append(GridLevel(interval: spBar * major, opacity: 0.16, kind: .barGroup))
            }
            levels.append(GridLevel(interval: spBar * anchor,
                                    opacity: major > anchor ? 0.10 : 0.16,
                                    kind: anchor > 1 ? .barGroup : .bar))
            // Individual bars fallen below the anchor: kept as ghosts for as long as they
            // stay legible, otherwise the density would jump by a factor of 4 from one step to the next.
            if anchor > 1 && barPx >= barGhostThresholdPx {
                levels.append(GridLevel(interval: spBar, opacity: 0.05, kind: .bar))
            }
            if !showBeat && timeSigNumerator >= 4 && spBar / 2.0 * pixelsPerSecond > bpmGridThresholdPx {
                levels.append(GridLevel(interval: spBar / 2.0, opacity: 0.08, kind: .halfBar))
            }
            if showBeat                          { levels.append(GridLevel(interval: spb,     opacity: 0.16,  kind: .beat))        }
            if bpx / 2.0 > bpmGridThresholdPx   { levels.append(GridLevel(interval: spb / 2, opacity: 0.08, kind: .halfBeat))    }
            if bpx / 4.0 > bpmGridThresholdPx   { levels.append(GridLevel(interval: spb / 4, opacity: 0.04, kind: .quarterBeat)) }
            return levels
        } else {
            let fine  = TimeLadder.interval(pixelsPerSecond: pixelsPerSecond, minPx: bpmGridThresholdPx)
            let major = TimeLadder.interval(pixelsPerSecond: pixelsPerSecond, minPx: gridMajorThresholdPx)
            if major == fine { return [GridLevel(interval: fine, opacity: 0.16, kind: .fine)] }
            return [GridLevel(interval: major, opacity: 0.12, kind: .major),
                    GridLevel(interval: fine,  opacity: 0.08, kind: .fine)]
        }
    }

    var effectiveSnapGrid: Double { gridLevels.last?.interval ?? 1.0 }

    /// A pure snap (the grid + object edges), with NO side effect. Usable on every
    /// mouse move (a cut preview) without mutating `objectSnapGuide`.
    func snappedTimePure(_ t: Double, excluding: Set<UUID> = []) -> Double {
        guard effectiveSnapEnabled else { return t }
        let g = effectiveSnapGrid
        let gridSnap = g > 0 ? (t / g).rounded() * g : t
        let threshold = 8.0 / pixelsPerSecond
        var bestObject: Double? = nil
        for item in items where !excluding.contains(item.id) {
            for edge in [item.startTime, item.startTime + item.duration] {
                guard abs(edge - t) <= threshold else { continue }
                if bestObject == nil || abs(edge - t) < abs(bestObject! - t) {
                    bestObject = edge
                }
            }
        }
        if let obj = bestObject, abs(obj - t) < abs(gridSnap - t) { return obj }
        return gridSnap
    }

    func snapTime(_ t: Double, excluding: Set<UUID> = []) -> Double {
        let snapped = snappedTimePure(t, excluding: excluding)
        let g = effectiveSnapGrid
        let gridSnap = g > 0 ? (t / g).rounded() * g : t
        objectSnapGuide = (effectiveSnapEnabled && snapped != gridSnap) ? snapped : nil
        return snapped
    }

    var isDirty: Bool = false {
        didSet {
            updateWindowTitle()
            // The central way through: almost every audio mutation ends with `isDirty =
            // true`. While a sound object is open, this arms the re-mirroring of the other
            // instances. LIVE knob movements (outside the model) are caught as well through
            // the engine's parameter listening. See EditViewModel+Objects.
            if editingDefinitionID != nil { scheduleLiveMirror() }
        }
    }
    var projectName: String = L("project.untitled") {
        didSet { updateWindowTitle() }
    }
    /// The URL of the current project file (nil for as long as it has never been saved).
    /// Tells "Save" (writes here) from "Save as" (opens a panel).
    var projectURL: URL? = nil

    /// The last 10 projects opened/saved (most-recent-first), persisted
    /// in UserDefaults. Observed so that the "Recent projects" sub-menu
    /// rebuilds itself automatically.
    var recentProjects: [URL] = EditViewModel.loadRecentProjects()

    var undoStack: [EditSnapshot] = []
    var redoStack: [EditSnapshot] = []

    var availablePlugins: [AvailablePlugin] = []
    var isScanning: Bool = false

    /// An accumulator of the plugins that could not be found during a LOAD (a project or an object).
    /// `compileRack` drops into it the name of the plugins the engine could not resolve for as long as it is
    /// non-nil; `applyProjectDocument` arms it at the start and shows a summary at the end. Outside
    /// a load it stays nil → normal editing (adding a plugin) does not alert here.
    var missingPluginCapture: Set<String>? = nil

    /// A perf note: the number of plugin states re-read from the engine during the capture under way.
    /// Reset by `currentSnapshot`, which journals it with the time spent — an AU's `getState`
    /// (a binary chunk + XML + string copies) is not free, and the capture sweeps
    /// the WHOLE project on every undoable gesture. @see EditViewModel+UndoRedo.
    @ObservationIgnored var pluginStateCaptureCount = 0

    // MARK: - Selection

    var selectedID: UUID? { selectedIDs.first }

    var selectedObject: SoundObject? {
        guard let id = selectedIDs.first else { return nil }
        return find(id: id)
    }

    func isSelected(_ id: UUID) -> Bool { selectedIDs.contains(id) }

    /// Renames an object. For a SHARED object, the name is SYNCHRONISED across every placement
    /// of the same definition (the same logic as the custom colour, see
    /// EditViewModel+ObjectColor) — a linked object keeps a consistent name everywhere it appears.
    func renameObject(id: UUID, label: String) {
        let newLabel = label.isEmpty ? nil : label
        var targets: Set<UUID> = [id]
        let defID = find(id: id)?.definitionID
        if let defID {
            targets.formUnion(placementIDs(forDefinition: defID))
        }
        pushUndo()
        for tid in targets {
            update(id: tid) { $0.label = newLabel }
        }
        // The DEFINITION's name follows too (it stayed frozen until the next re-bake).
        if let defID, let newLabel { objectDefinitions[defID]?.name = newLabel }
        isDirty = true
    }

    func updateReversed(id: UUID, reversed: Bool) {
        update(id: id) { obj in
            guard case .clip(let fp, let so, let fd, let sr, let was) = obj.kind else { return }
            guard was != reversed else { return }
            obj.kind = .clip(filePath: fp, sourceOffset: so, fileDuration: fd,
                             speedRatio: sr, isReversed: reversed)
            // The loop is not handled in reverse (@see SoundObject.canLoop, [[loop-item-plan]]):
            // if the loop has to be cut in order to reverse, cut it for good rather than
            // leave it active on the model side but ignored on the engine side.
            if reversed { obj.loopEnabled = false }
            // The matter turns round inside the window: what was heard at `t` is now
            // heard at `duration - t`. The curves follow, curvature included (@see
            // AutomationLane.mirrored) — otherwise a fade drawn on the end of a sound would
            // end up on its attack.
            obj.automation = obj.automation.mirroredInTime(over: obj.duration)
        }
        engine?.updateIsReversed(reversed, forID: id.uuidString)
        // Turning the playback round changes the offset CONVENTION on the engine side (Tracktion then reads a
        // reversed proxy, and recomputes the offset in its own way in reverseLoopPoints): the model's
        // geometry is laid over it so that IT is the authority — otherwise a varispeeded clip
        // shifted inside its file at the moment of the turn.
        // `syncPosition` pushes the turned curves along the way (@see mirroredInTime).
        if let obj = find(id: id) { syncPosition(obj) }
        isDirty = true
    }

    /// Toggles an object's loop: its content (the IN/OUT bounds, @see SoundObject.loopRangeStart)
    /// repeats for as long as the object's window overruns it, instead of leaving silence
    /// (@see SoundObject.canLoop, [[loop-item-plan]]). The first activation: the bounds are laid
    /// on the size current AT THAT MOMENT (`[0, duration]`) then stay frozen for the following
    /// activations — turning it off and on again does not lose an IN/OUT setting already made.
    func updateLoopEnabled(id: UUID, enabled: Bool) {
        guard find(id: id)?.canLoop == true else { return }
        update(id: id) {
            $0.loopEnabled = enabled
            if enabled, $0.loopRangeStart == nil {
                $0.loopRangeStart = 0
                $0.loopRangeEnd   = $0.duration
            }
        }
        guard let obj = find(id: id) else { return }
        switch obj.kind {
        case .clip:     syncPosition(obj)
        case .group:    syncGroupWindow(obj)
        case .midiClip: syncMidiLoop(obj)
        case .aux:      break
        }
        isDirty = true
    }

    /// Moves the IN/OUT bounds of an already active loop (dragging the markers, or
    /// `object.set_loop_range`) — in SECONDS LOCAL TO THE OBJECT, @see SoundObject.loopRangeStart.
    func updateLoopRange(id: UUID, start: Double, end: Double) {
        guard let obj0 = find(id: id), obj0.canLoop, obj0.loopEnabled, end > start else { return }
        update(id: id) { $0.loopRangeStart = start; $0.loopRangeEnd = end }
        guard let obj = find(id: id) else { return }
        switch obj.kind {
        case .clip:     syncPosition(obj)
        case .group:    syncGroupWindow(obj)
        case .midiClip: syncMidiLoop(obj)
        case .aux:      break
        }
        isDirty = true
    }

    /// Pushes the MIDI loop to the engine, the IN/OUT bounds converted SECONDS → BEATS through the current
    /// tempo (`te::MidiClip` loops in beats, @see OBJEngineCore.mm setMidiLoop:).
    private func syncMidiLoop(_ obj: SoundObject) {
        guard case .midiClip = obj.kind else { return }
        guard obj.loopEnabled, let s = obj.loopRangeStart, let e = obj.loopRangeEnd, e > s else {
            engine?.setMidiLoop(false, startBeats: 0, endBeats: 0, forID: obj.id.uuidString)
            return
        }
        let secPerBeat = 60.0 / tempo
        engine?.setMidiLoop(true, startBeats: s / secPerBeat, endBeats: e / secPerBeat,
                            forID: obj.id.uuidString)
    }

    /// The IN/OUT bounds of a looping audio clip, converted from the LOCAL frame (object seconds,
    /// @see SoundObject.loopRangeStart) to the FILE frame the engine expects — through
    /// `sourceOffset ± ×speedRatio`, like the rest of the clip↔file conversions. It can overrun
    /// `[0, duration]` (a sampler-style loop point, @see [[loop-item-plan]]); bounded to
    /// `[0, fileDuration]`.
    func clipLoopFileBounds(_ obj: SoundObject) -> (start: Double, end: Double) {
        guard case .clip(_, let sourceOffset, let fileDuration, let speedRatio, _) = obj.kind
        else { return (0, 0) }
        let localStart = obj.loopRangeStart ?? 0
        let localEnd   = obj.loopRangeEnd ?? obj.duration
        let fileStart = max(0, sourceOffset + localStart * speedRatio)
        let fileEnd   = min(fileDuration, sourceOffset + localEnd * speedRatio)
        return (fileStart, fileEnd)
    }

    /// The maximum duration of a clip before it touches the next clip/group on its lane
    /// (.infinity if there is nothing after). Handles top-level and a child of a group.
    private func availableDurationBeforeNext(id: UUID) -> Double {
        guard let obj = find(id: id) else { return .infinity }
        let siblings: [SoundObject]
        if let parent = parentGroup(for: id), case .group(let kids, _) = parent.kind {
            siblings = kids
        } else {
            siblings = items
        }
        let nextStart = siblings
            .filter { $0.id != id && $0.lane == obj.lane && $0.startTime > obj.startTime }
            .map(\.startTime)
            .min()
        guard let ns = nextStart else { return .infinity }
        return max(0.01, ns - obj.startTime)
    }

    func updateSpeed(id: UUID, ratio: Double) {
        let newSpeed = max(0.0625, min(16.0, ratio))  // ±48 semitones (2^±4)
        // Non-destructive: the lengthening by varispeed must not overlap the next clip.
        // NB: a "quick" choice — the stored duration is trimmed, so resetting the pitch does not restore it.
        let gap = availableDurationBeforeNext(id: id)
        update(id: id) { obj in
            guard case .clip(let fp, let so, let fd, let oldSpeed, let rev) = obj.kind else { return }
            // Varispeed: the source content is preserved → the timeline duration varies as 1/speed
            // (speeding up shortens the clip). Never beyond the content available.
            let oldSourceSpan = obj.duration * oldSpeed      // the source range taken up, before
            var D = obj.duration * oldSpeed / newSpeed
            // The content available from the entry point: played forwards, what follows `so`;
            // in reverse the playback goes back up the range, hence what PRECEDES its end.
            let available = rev ? (so + oldSourceSpan) : max(0, fd - so)
            if fd > 0 { D = min(D, available / newSpeed) }
            D = min(D, gap)
            D = max(0.01, D)
            var fi = obj.fadeIn, fo = obj.fadeOut
            if D < fi { fi = D; fo = 0 } else if D < fi + fo { fo = D - fi }
            obj.duration = D
            obj.fadeIn   = fi
            obj.fadeOut  = fo
            // The window keeps its LEFT edge: the content heard at the clip's entry does not
            // move. Played forwards that is the offset itself; in reverse, the entry is the END
            // of the source range, which therefore has to be held by moving the offset back by as much as
            // the range lengthens (@see WaveformShaping.retrimmedSourceOffset).
            let newSO = rev ? max(0, so + oldSourceSpan - D * newSpeed) : so
            obj.kind = .clip(filePath: fp, sourceOffset: newSO, fileDuration: fd,
                             speedRatio: newSpeed, isReversed: rev)
            // Timeline time stretches by `oldSpeed / newSpeed` in front of the same source
            // matter: the automation points rescale by the same factor to
            // stay in front of what they modulate. It is taken from the SPEEDS and not from the
            // durations: the duration may have been trimmed by the content available or by the neighbour
            // (D is bounded above), and a curve must not compress for that
            // reason — the points that overrun stay stored, as after a trim.
            obj.automation = obj.automation.timeScaled(by: oldSpeed / newSpeed)
        }
        engine?.updateSpeedRatio(newSpeed, forID: id.uuidString)
        if let obj = find(id: id) {
            syncPosition(obj)
            engine?.updateFade(in: obj.fadeIn, fadeOut: obj.fadeOut, forID: id.uuidString)
        }
        isDirty = true
    }

    func updateBaseBPM(id: UUID, bpm: Double?) {
        update(id: id) { obj in obj.baseBPM = bpm }
        isDirty = true
    }

    // MARK: - Recursive helpers

    func find(id: UUID) -> SoundObject? {
        func search(in arr: [SoundObject]) -> SoundObject? {
            for item in arr {
                if item.id == id { return item }
                if case .group(let children, _) = item.kind,
                   let found = search(in: children) { return found }
            }
            return nil
        }
        return search(in: items)
    }

    @discardableResult
    func update(id: UUID, transform: (inout SoundObject) -> Void) -> Bool {
        func apply(in arr: inout [SoundObject]) -> Bool {
            for i in arr.indices {
                if arr[i].id == id { transform(&arr[i]); return true }
                if case .group(var children, let isExpanded) = arr[i].kind {
                    if apply(in: &children) {
                        arr[i].kind = .group(children: children, isExpanded: isExpanded)
                        return true
                    }
                }
            }
            return false
        }
        return apply(in: &items)
    }

    // MARK: - Internal helpers

    func updateWindowTitle() {
        let title = isDirty ? "\(projectName) •" : projectName
        NSApp.mainWindow?.title = title
    }

    /// Adds a `.clip` object to the engine at its ABSOLUTE position, on its own track.
    /// Includes volume/pan/fades/speed/reverse/plugins. Does NOT handle membership of a
    /// group or a stem (the routing — assignObject:toGroupFolder: / assignObjects:toStemID:
    /// — is laid by the caller). Reused for top-level clips AND for children of groups
    /// (a child = a top-level clip + an assign into the folder).
    /// `lane` forces the engine lane (the carrying track): used for a child of a group, whose
    /// model lane is relative to the group — it is then born on the group's lane before
    /// being moved into its ContainerClip.
    func engineAddClip(_ object: SoundObject, lane: Int? = nil) {
        guard let engine,
              case .clip(let filePath, let sourceOffset, _, let speedRatio, let isReversed) = object.kind
        else { return }
        let data = OBJSoundObjectData()
        data.lane         = lane ?? object.lane
        data.filePath     = filePath
        data.startTime    = object.startTime
        data.duration     = object.duration
        data.volume       = engineVolume(for: object)
        data.pan          = object.pan
        data.fadeIn       = object.fadeIn
        data.fadeOut      = object.fadeOut
        data.sourceOffset = sourceOffset
        engine.addSoundObject(data, withID: object.id.uuidString)
        if isReversed      { engine.updateIsReversed(true, forID: object.id.uuidString) }
        if speedRatio != 1.0 { engine.updateSpeedRatio(speedRatio, forID: object.id.uuidString) }
        // Reverse: the offset laid by `addSoundObject` has been turned round by Tracktion according to ITS
        // rule (and even before knowing the speed). The model's is laid again, converted
        // into the reversed convention — otherwise a reversed clip reloaded did not enter its
        // file at the right place. A no-op for clips played forwards, hence the test.
        // Loop: `addSoundObject` never lays the loop range — only `updatePosition`
        // does — so an object freshly created with the loop already active needs this
        // same corrective pass.
        if isReversed || object.loopEnabled {
            let loopBounds = clipLoopFileBounds(object)
            engine.updatePosition(object.startTime, duration: object.duration,
                                  sourceOffset: sourceOffset, loopEnabled: object.loopEnabled,
                                  loopRangeStart: loopBounds.start, loopRangeEnd: loopBounds.end,
                                  forID: object.id.uuidString)
        }
        // Compiles as well when the chain holds ONLY trim gains (with no plugin):
        // otherwise the synoptic's trims were never reapplied on loading/pasting.
        if object.needsChainCompile { syncPlugins(object) }
    }

    /// Adds a `.midiClip` object to the engine: ContainerClip + a child MIDI clip + the instrument
    /// (index 0 of the container's chain) + the notes + the FX. The same contract as `engineAddClip` (no
    /// group/stem routing; laid by the caller), `lane` included.
    /// See [[project_midi_integration]].
    func engineAddMidiClip(_ object: SoundObject, lane: Int? = nil) {
        guard let engine, case .midiClip = object.kind else { return }
        let data = OBJSoundObjectData()
        data.lane         = lane ?? object.lane
        data.filePath     = ""
        data.startTime    = object.startTime
        data.duration     = object.duration
        data.volume       = engineVolume(for: object)
        data.pan          = object.pan
        data.fadeIn       = object.fadeIn
        data.fadeOut      = object.fadeOut
        data.sourceOffset = 0
        engine.addMidiClip(data, withID: object.id.uuidString)
        syncInstruments(object)
        syncMidiNotes(object)
        // An object freshly created with the loop already active (paste/duplication): `addMidiClip`
        // never lays the loop range, only `updateLoopEnabled`/`updateLoopRange` normally
        // do. @see [[loop-item-plan]]
        syncMidiLoop(object)
        if object.needsChainCompile { syncPlugins(object) }
    }

    /// (Re)pushes the MIDI clip's notes to the engine (replacing the MidiList). Timing in BEATS.
    func syncMidiNotes(_ object: SoundObject) {
        guard let engine, case .midiClip = object.kind else { return }
        // `startBeat < 0` = a note masked by the left trim (it still lives in the model,
        // reopening the edge gives it back). It is not pushed: the engine has nothing to do with a
        // negative beat position, and the DAW convention has it that a note whose attack is
        // trimmed is not re-triggered at the edge (see `splitMidiNotes`).
        let notes: [[String: Any]] = object.midiNotes.filter { $0.startBeat >= 0 }.map { n in
            ["pitch": n.pitch, "start": n.startBeat, "length": n.lengthBeats, "velocity": n.velocity]
        }
        engine.setMidiNotes(notes, forID: object.id.uuidString)
    }

    /// Adds an `.aux` object to the engine: a ContainerClip marked as an aux bus + fader + FX. Like
    /// `engineAddClip`, it does not handle group/stem membership (laid by the caller).
    /// `lane`: the aux's if it is top-level, the GROUP's if it enters one — in the
    /// latter case it only passes through the track before assignObject moves it.
    func engineAddAux(_ object: SoundObject, lane: Int? = nil) {
        guard let engine, case .aux = object.kind else { return }
        engine.createAux(object.id.uuidString, lane: lane ?? object.lane)
        engine.updateVolume(engineVolume(for: object), pan: object.pan,
                            forID: object.id.uuidString)
        syncAuxWindow(object)
        if object.needsChainCompile { syncPlugins(object) }
    }

    /// The "infinite" window end pushed to the engine for an infinite bus: a very large value (s)
    /// → the gate stays open over the whole practical length of a project.
    static let infiniteWindowEnd: Double = 1_000_000_000

    /// Pushes the aux's bounds (window) + fades: fadeIn = the entry gate, fadeOut = the tail (exit).
    /// An aux marked INFINITE ignores start/end: a [0, ∞) window, with no fades → a bus always active.
    func syncAuxWindow(_ object: SoundObject) {
        guard case .aux = object.kind else { return }
        if object.isInfinite {
            engine?.updateAuxWindow(object.id.uuidString,
                                    start: 0, end: Self.infiniteWindowEnd,
                                    fadeIn: 0, fadeOut: 0)
        } else {
            engine?.updateAuxWindow(object.id.uuidString,
                                    start: object.startTime, end: object.startTime + object.duration,
                                    fadeIn: object.fadeIn, fadeOut: object.fadeOut)
        }
    }

    /// (Re)pushes to the engine the post-fader sends of a sender towards its auxes.
    /// The target auxes must already exist on the engine side.
    func syncSends(_ object: SoundObject) {
        // `canRouteSend`: the engine only wires a send between siblings of the same group. The
        // others stay in the model, silent — not pushing them to it avoids a no-op
        // journalled on every reload. @see EditViewModel+Aux
        for send in object.sends where send.isRouted && canRouteSend(from: object.id, to: send.auxID) {
            engine?.addSend(object.id.uuidString, toAux: send.auxID.uuidString, levelDb: send.levelDb)
        }
    }

    func syncAdd(_ object: SoundObject) {
        guard let engine else { return }
        switch object.kind {
        case .clip:
            engineAddClip(object)
            if let sid = object.stemID {
                engine.assignObjects([object.id.uuidString], toStemID: sid.uuidString)
            }
            syncSends(object)
        case .midiClip:
            engineAddMidiClip(object)
            if let sid = object.stemID {
                engine.assignObjects([object.id.uuidString], toStemID: sid.uuidString)
            }
            syncSends(object)
        case .aux:
            engineAddAux(object)
            if let sid = object.stemID {
                engine.assignObjects([object.id.uuidString], toStemID: sid.uuidString)
            }
        case .group(let children, _):
            syncAddGroup(object, children: children, parentGroupID: nil, absoluteParentStart: 0)
        }
        // The plugins carrying the curves have just been born: push again from the model.
        // (The sends of an aux not created yet will be caught up by `resyncAllSends`.)
        pushAutomationTree(object)
    }

    func syncPosition(_ object: SoundObject) {
        switch object.kind {
        case .clip(_, let sourceOffset, _, _, _):
            // An ABSOLUTE position, including for a child of a group (its ContainerClip has a
            // null offset → local time = edit time).
            let loopBounds = clipLoopFileBounds(object)
            engine?.updatePosition(object.startTime, duration: object.duration,
                                   sourceOffset: sourceOffset, loopEnabled: object.loopEnabled,
                                   loopRangeStart: loopBounds.start, loopRangeEnd: loopBounds.end,
                                   forID: object.id.uuidString)
            // A lane = a track: changing lane moves the clip to another carrying track.
            // A no-op on the engine side if the lane has not moved, or if the object lives inside a group.
            engine?.setLane(object.lane, forID: object.id.uuidString)
        case .midiClip:
            // A MIDI object = a ContainerClip + a child MIDI clip; no source offset. The engine
            // realigns the container's span on the clip that was moved.
            engine?.updatePosition(object.startTime, duration: object.duration,
                                   sourceOffset: 0, loopEnabled: false,
                                   loopRangeStart: 0, loopRangeEnd: 0, forID: object.id.uuidString)
            // And its lane moves it to another carrying track, like an audio clip (a no-op if it is
            // the child of a group: it then lives in the group's container).
            engine?.setLane(object.lane, forID: object.id.uuidString)
        case .aux:
            // An aux's "position" is its window — that is what bounds its return.
            syncAuxWindow(object)
            // And its lane is pushed to the engine as for any top-level object: it only serves
            // the track allocation there (a no-op if it is the child of a group — it then lives in the
            // container, which has no track of its own).
            engine?.setLane(object.lane, forID: object.id.uuidString)
        case .group(let children, _):
            // A group's folder has NO timeline position (a double identity: the position
            // is a pure model fact). Moving a group = repositioning its descendant clips,
            // whose absolute startTime has already been updated in the model (shiftStartTimes).
            repositionDescendantClips(children)
            // The group's ContainerClip follows its lane (its children travel with it).
            engine?.setLane(object.lane, forID: object.id.uuidString)
            // The group's bounds (window) have moved → update the window+fade plugin.
            syncGroupWindow(object)
        }
        // The points are stored in RELATIVE time: moving or trimming the object does not touch them,
        // but changes their EDIT time. Hence the systematic push again, here and nowhere else —
        // `syncPosition` is the one way through for every geometry change (a move, a trim, a lane,
        // entering/leaving a group). The whole tree for a group: its children have moved with it.
        pushAutomationTree(object)
    }

    /// Pushes to the engine the absolute position of every descendant clip (sub-groups included).
    func repositionDescendantClips(_ children: [SoundObject]) {
        for child in children {
            switch child.kind {
            case .clip(_, let so, _, _, _):
                let loopBounds = clipLoopFileBounds(child)
                engine?.updatePosition(child.startTime, duration: child.duration,
                                       sourceOffset: so, loopEnabled: child.loopEnabled,
                                       loopRangeStart: loopBounds.start, loopRangeEnd: loopBounds.end,
                                       forID: child.id.uuidString)
            case .midiClip:
                engine?.updatePosition(child.startTime, duration: child.duration,
                                       sourceOffset: 0, loopEnabled: false,
                                       loopRangeStart: 0, loopRangeEnd: 0, forID: child.id.uuidString)
            case .aux:
                syncAuxWindow(child)
            case .group(let grandchildren, _):
                repositionDescendantClips(grandchildren)
                // The window (gate) of a SUB-group is in seconds: without this push it stayed
                // on the bounds from BEFORE the parent's move (or the tempo remap), and the
                // engine cut the sub-group's inside at the old bounds — invisible on
                // screen (the model, for its part, is right) and "repaired" by a plain reload,
                // which goes through syncAddGroup again.
                syncGroupWindow(child)
            }
        }
    }

    /// Realigns the model on the engine after a tempo remap (BPM mode).
    ///
    /// `remapRatio` = the old tempo / the new tempo, that is the time-stretching factor.
    /// - An audio / MIDI clip: its position re-read from the engine (the truth), which has remapped the tracks.
    /// - A MIDI clip: its LENGTH is musical (notes in beats) → its duration in seconds follows
    ///   the ratio, otherwise the block keeps its earlier dimensions while the notes move.
    /// - An aux: its window is a pure MODEL fact (no engine clip) → stretched by the ratio.
    /// - A group: its START is a musical anchor (stretched by the ratio), but its END realigns
    ///   on the real end of its content when the window already matched it — an audio clip
    ///   keeps its length (autoTempo off), so an end simply stretched would cut its tail
    ///   when the tempo goes up. A deliberately wider window ⇒ the stretching is kept.
    /// The windows pushed to the engine (ObjWindowFade, in seconds) do not follow the remap:
    /// they are all pushed again at the end of the pass.
    func resyncPositionsFromTracktion(remapRatio: Double = 1.0) {
        guard let engine else { return }
        let scale = (remapRatio.isFinite && remapRatio > 0) ? remapRatio : 1.0
        // The tolerance for judging that a window "matches" its content (floating-point rounding).
        let hugEps = 0.001
        func resync(in arr: inout [SoundObject]) {
            for i in arr.indices {
                switch arr[i].kind {
                case .clip:
                    let t = engine.getClipStartTime(forID: arr[i].id.uuidString)
                    if t >= 0 { arr[i].startTime = t }
                case .midiClip:
                    let t = engine.getClipStartTime(forID: arr[i].id.uuidString)
                    if t >= 0 { arr[i].startTime = t }
                    if scale != 1 { arr[i].duration = max(0.01, arr[i].duration * scale) }
                case .aux:
                    if scale != 1 {
                        arr[i].startTime *= scale
                        arr[i].duration = max(0.01, arr[i].duration * scale)
                    }
                case .group(var children, let isExpanded):
                    // The bounds BEFORE the remap: they say whether the window matched its content exactly.
                    let oldStart = arr[i].startTime
                    let oldEnd   = oldStart + arr[i].duration
                    let oldHi    = children.map { $0.startTime + $0.duration }.max()
                    // Descending first: the end realigns on children ALREADY remapped.
                    resync(in: &children)
                    arr[i].kind = .group(children: children, isExpanded: isExpanded)
                    guard scale != 1 else { break }
                    let newStart = oldStart * scale
                    var newEnd   = newStart + arr[i].duration * scale
                    if let oldHi, let newHi = children.map({ $0.startTime + $0.duration }).max(),
                       abs(oldEnd - oldHi) <= hugEps {
                        newEnd = newHi
                    }
                    arr[i].startTime = newStart
                    arr[i].duration  = max(0.01, newEnd - newStart)
                }
            }
        }
        batchItemsMutation { resync(in: &items) }
        // The engine gates/windows are in seconds: they stay on the old bounds
        // after the remap → push the positions + windows again (recursive over the groups).
        if scale != 1 {
            for obj in items { syncPosition(obj) }
        }
    }

    /// Time mode: the tempo changes WITH NO remap — nothing moves in seconds. Except that a MIDI clip
    /// has musical content (notes in beats, on the engine side as on the model side): at the new tempo
    /// they play faster or slower. Without this pass, the block would keep its
    /// earlier width while its notes shifted, and the clip's gate would cut what
    /// overruns. So the length in seconds follows the tempo in BOTH grid modes; only
    /// the starting position stays frozen in Time mode.
    func rescaleMidiClipDurations(ratio: Double) {
        guard ratio.isFinite, ratio > 0, ratio != 1 else { return }
        var touched: [SoundObject] = []
        func rescale(in arr: inout [SoundObject]) {
            for i in arr.indices {
                switch arr[i].kind {
                case .midiClip:
                    arr[i].duration = max(0.01, arr[i].duration * ratio)
                    touched.append(arr[i])
                case .group(var children, let isExpanded):
                    rescale(in: &children)
                    arr[i].kind = .group(children: children, isExpanded: isExpanded)
                case .clip, .aux:
                    break
                }
            }
        }
        batchItemsMutation { rescale(in: &items) }
        // The position + gate (ObjWindowFade) of the MIDI clip, in seconds: to be pushed to the engine.
        for obj in touched {
            engine?.updatePosition(obj.startTime, duration: obj.duration,
                                   sourceOffset: 0, loopEnabled: false,
                                   loopRangeStart: 0, loopRangeEnd: 0, forID: obj.id.uuidString)
            pushAutomation(obj)   // the duration has changed, so the edit time of the points has too
        }
    }
}

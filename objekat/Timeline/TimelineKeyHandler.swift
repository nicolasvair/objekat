import AppKit
import SwiftUI

extension TimelineView {

    /// The silence beyond which a wheel notch opens a NEW setting gesture (and therefore a new
    /// undo). Below it, the notches chain within the same gesture.
    static let valueScrollUndoGap: TimeInterval = 0.5

    func registerScrollMonitor() {
        let vm       = viewModel
        let hs       = hoverState
        let rulerH   = rulerHeight

        /// True if this notch opens a new gesture (volume/pan/send by wheel): the caller then pushes
        /// an undo BEFORE applying, as a drag does at its start.
        func opensNewValueGesture(_ event: NSEvent) -> Bool {
            let now = ProcessInfo.processInfo.systemUptime
            let isNew = event.phase.contains(.began)
                     || now - hs.lastValueScrollTime > Self.valueScrollUndoGap
            hs.lastValueScrollTime = now
            return isNew
        }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let pos = hs.position else { return event }

            let pps = vm.pixelsPerSecond
            let bh  = vm.blockHeight
            let ls  = bh + 4.0

            // MARK: Shift+scroll = horizontal OR vertical zoom, never both at once.
            // A 'logical' gesture = the active phase (fingers) AND its inertia (momentum):
            // the axis is locked for that whole span and is never decided again along the way.
            // The decision is only rearmed at the START of a new gesture (the trackpad's .began
            // phase) or after a long silence (a mouse with no usable phase).
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.shift) {
                let now = ProcessInfo.processInfo.systemUptime
                let hasPhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty

                // Rearming: a new trackpad gesture (.began) OR, failing a phase (a mouse),
                // a generous idle timeout. NB: we most certainly do NOT reset on .ended, otherwise
                // the first inertia event would decide the axis again → both axes felt zooming
                // during a single gesture.
                let newGesture = event.phase.contains(.began)
                              || (!hasPhase && now - hs.shiftZoomLastEventTime > 0.4)
                if newGesture {
                    hs.shiftZoomAxis = nil
                    hs.shiftZoomAccumX = 0
                    hs.shiftZoomAccumY = 0
                }
                hs.shiftZoomLastEventTime = now

                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY

                // The axis is locked over a small accumulation window (noise protection for the
                // very first event, where dx≈dy). While the accumulated signal is too weak, we
                // engage no zoom (a dead zone of a few points, imperceptible).
                if hs.shiftZoomAxis == nil {
                    hs.shiftZoomAccumX += dx
                    hs.shiftZoomAccumY += dy
                    let ax = abs(hs.shiftZoomAccumX)
                    let ay = abs(hs.shiftZoomAccumY)
                    guard max(ax, ay) >= 3 else { return nil }
                    hs.shiftZoomAxis = ax >= ay ? .horizontal : .vertical
                }

                switch hs.shiftZoomAxis! {
                case .horizontal:
                    guard dx != 0 else { return nil }
                    let mult = exp(Double(dx) * 0.01)
                    DispatchQueue.main.async { self.applyZoom(vm.pixelsPerSecond * mult) }
                case .vertical:
                    guard dy != 0 else { return nil }
                    let mult = exp(Double(dy) * 0.012)
                    DispatchQueue.main.async { self.applyVerticalZoom(vm.blockHeight * mult) }
                }
                return nil
            }

            // MARK: Automation curvature (the wheel on a segment)
            // An alternative to ⌥dragging, and the only gesture of the band that does not go through
            // SwiftUI: there is no 'wheel' gesture on SwiftUI's side, and this monitor already has the
            // hover position. Independent of the active tool: an open band is an editing surface in
            // its own right. The wheel is only swallowed on a segment that really can be bent —
            // elsewhere in the band, it goes on scrolling the timeline.
            if let hit = self.automationCurveHit(at: pos) {
                hs.automationScrollAccumulator -= Float(event.scrollingDeltaY * 0.1)
                let steps = Int(hs.automationScrollAccumulator.rounded())
                if steps != 0 {
                    hs.automationScrollAccumulator -= Float(steps)
                    let newGesture = opensNewValueGesture(event)
                    DispatchQueue.main.async {
                        if newGesture { vm.beginAutomationEdit() }
                        vm.adjustAutomationCurvature(objectID: hit.objectID, param: hit.param,
                                                     at: hit.pointIndex, steps: steps)
                    }
                }
                return nil
            }

            // MARK: Volume scroll (deltaY, the ≥ 60% right zone)
            if vm.activeTool == .toolVolume {
                guard let entry = vm.laneEntries.first(where: { e in
                    let bx = e.absStart * pps
                    let bw = max(e.item.duration * pps, 2)
                    let by = rulerH + Double(e.displayLane) * ls
                    return pos.x >= bx && pos.x <= bx + bw && pos.y >= by && pos.y <= by + bh
                }) else { return event }
                let item = entry.item
                let bx   = entry.absStart * pps
                let bw   = max(item.duration * pps, 2)
                guard (pos.x - bx) >= bw * 0.6 else { return event }

                hs.scrollAccumulator -= Float(event.scrollingDeltaY * 0.1)
                let steps = Int(hs.scrollAccumulator.rounded())
                if steps != 0 {
                    hs.scrollAccumulator -= Float(steps)
                    let newGesture = opensNewValueGesture(event)
                    DispatchQueue.main.async {
                        if newGesture { vm.pushUndo() }
                        if !vm.selectedIDs.contains(item.id) {
                            vm.select(item.id, additive: false)
                        }
                        vm.adjustVolumeDB(Float(steps))
                    }
                }
                return nil
            }

            // MARK: Pan scroll (deltaY, the whole item)
            // Vertical like the volume and the sends: since pan is shown as a knob, it is the
            // same wheel gesture everywhere (up = to the right).
            if vm.activeTool == .toolPan {
                guard event.scrollingDeltaY != 0 else { return event }

                guard let entry = vm.laneEntries.first(where: { e in
                    let bx = e.absStart * pps
                    let bw = max(e.item.duration * pps, 2)
                    let by = rulerH + Double(e.displayLane) * ls
                    return pos.x >= bx && pos.x <= bx + bw && pos.y >= by && pos.y <= by + bh
                }) else { return event }
                let item = entry.item

                hs.panScrollAccumulator -= Float(event.scrollingDeltaY * 0.1)
                let steps = Int(hs.panScrollAccumulator.rounded())
                if steps != 0 {
                    hs.panScrollAccumulator -= Float(steps)
                    let newGesture = opensNewValueGesture(event)
                    DispatchQueue.main.async {
                        if newGesture { vm.pushUndo() }
                        if !vm.selectedIDs.contains(item.id) {
                            vm.select(item.id, additive: false)
                        }
                        vm.adjustPanSelected(Float(steps) * 0.1)
                    }
                }
                return nil
            }

            // MARK: Send scroll (deltaY over the knob column under the cursor, the aux tool)
            // An alternative to the drag: each notch ≈ 1 dB of send towards that aux, applied to the
            // whole selection overlapping the aux (like the drag). ⇧+scroll is still the zoom.
            if vm.activeTool == .toolAux {
                guard let hit = self.sendRowHit(at: pos) else { return event }
                hs.sendScrollAccumulator -= Float(event.scrollingDeltaY * 0.1)
                let steps = Int(hs.sendScrollAccumulator.rounded())
                if steps != 0 {
                    hs.sendScrollAccumulator -= Float(steps)
                    let newGesture = opensNewValueGesture(event)
                    DispatchQueue.main.async {
                        if newGesture { vm.pushUndo() }
                        if !vm.selectedIDs.contains(hit.clipID) {
                            vm.select(hit.clipID, additive: false)
                        }
                        vm.sendToolFocus = SendFocus(objectID: hit.clipID, auxID: hit.auxID)
                        vm.adjustSendLevelSelected(toAux: hit.auxID, deltaDb: Float(steps))
                    }
                }
                return nil
            }

            return event
        }
    }

    /// A trackpad pinch = horizontal zoom, by the SAME path as ⇧wheel and the pills:
    /// multiplicative notches on `applyZoom`, inside a session held open from the first to the
    /// last event (hence ONE anchor for the whole gesture).
    ///
    /// It used to be a SwiftUI `MagnificationGesture`, whose value is CUMULATIVE from the start of
    /// the gesture. So the starting zoom had to be remembered and `base × factor` recomputed on
    /// every event — and above all that computation had to be redone in `onEnded`, whose final
    /// value is not reliable on a trackpad: it went back to 1, and the zoom jumped at once to its
    /// starting value at the end of the pinch. `NSEvent.magnification` is a DELTA per event:
    /// nothing left to remember, and the end of the gesture merely closes the session.
    func registerMagnifyMonitor() {
        let vm = viewModel
        let hs = hoverState

        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            // Like the wheel: only a pinch over the timeline zooms it.
            guard hs.position != nil else { return event }

            if event.phase.contains(.began) {
                DispatchQueue.main.async { vm.beginHorizontalZoomDrag?() }
            }
            if event.magnification != 0 {
                let mult = 1 + Double(event.magnification)
                DispatchQueue.main.async { vm.applyHorizontalZoom?(vm.pixelsPerSecond * mult) }
            }
            if !event.phase.intersection([.ended, .cancelled]).isEmpty {
                DispatchQueue.main.async { vm.endHorizontalZoomDrag?() }
            }
            return nil
        }
    }

    /// Text is being typed somewhere in the app: the keys belong to it, and the monitor has to let
    /// them through untouched. Three worlds to ask:
    ///  - AppKit: our SwiftUI fields and the plugins' native Cocoa views (an NSTextField
    ///    delegates its typing to its field editor, which is an NSTextView);
    ///  - JUCE: a JUCE plugin's GUI is a single NSView, and no native field has focus in it —
    ///    the engine has to be asked which JUCE component holds it (@see isEditingTextInPluginEditor).
    ///    Without that test, typing a preset's name in an AU triggered the tool shortcuts;
    ///  - OUT OF PROCESS: the key window may be ours only by its frame (@see
    ///    isSystemPanelKey).
    func isTextInputActive() -> Bool {
        guard let key = NSApp.keyWindow else {
            return viewModel.engine?.isEditingTextInPluginEditor() ?? false
        }
        if key.firstResponder is NSTextView { return true }
        if Self.isSystemPanelKey(key) { return true }
        return viewModel.engine?.isEditingTextInPluginEditor() ?? false
    }

    /// True if the key window is a SYSTEM panel whose content lives in ANOTHER process — 'Save
    /// As…', 'Open…', share sheets: their inside is an `NSRemoteView`, a mere porthole onto a UI
    /// that is not ours.
    ///
    /// The field editor test can see NOTHING there: the 'Name' field does not exist in our memory
    /// space, so `firstResponder` stays the panel itself and never an NSTextView.
    /// Our monitor, on the other hand, sees the event first — ⌘C/⌘V/⌘X while one was naming a
    /// file therefore applied to the session's OBJECTS instead of the name being edited
    /// (and ⌘A, ⌘Z and Delete with them).
    ///
    /// NB: the panel is out of process even outside the sandbox — checked by inspecting its
    /// `contentView`, which is an `NSRemoteView` from its creation.
    static func isSystemPanelKey(_ window: NSWindow) -> Bool {
        if window is NSSavePanel { return true }          // NSOpenPanel inherits from it
        guard let remoteClass = NSClassFromString("NSRemoteView"),
              let content = window.contentView else { return false }
        // A short sweep: the remote view is the panel's content, or just under it.
        return content.isKind(of: remoteClass)
            || content.subviews.contains { $0.isKind(of: remoteClass) }
    }

    func registerKeyMonitor() {
        let vm = viewModel
        let isTextInput = isTextInputActive
        let togglePlayback = onTogglePlayback
        let togglePause = onTogglePause
        let returnToZero = onReturnToZero
        let soloPlay = onSoloPlay
        // Synchronous tracking of the physically held 's' key: it arms the solo chords
        // (s+Return, s+space, s+N). It lives in the monitor's closure (the same thread as the
        // events) → readable with no latency by the switch's other cases.
        let chord = SoloChordState()
        // Holding a key → the cheat sheet (see ShortcutCheatsheet). The same lifetime as the
        // solo chord: the monitor's closure.
        let cheat = CheatsheetHold()

        // ⌘-Tab: the app loses focus while ⌘ is DOWN, and its release goes to the next
        // application — the monitor below is LOCAL, it never sees it. So ⌘ stayed 'held' on the
        // way back (an inverted snap, an armed cheat sheet), and likewise for the tool key or the
        // solo 's' held at the moment of the switch. The rule: with no focus, no key is held any
        // more; on coming back, we reread the keyboard's real state.
        let center = NotificationCenter.default
        focusObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification,
                               object: nil, queue: .main) { _ in
                cheat.schedule(nil, in: vm)
                let auditioning = chord.didAudition
                chord.keyCode = nil
                chord.didAudition = false
                MainActor.assumeIsolated {
                    vm.cmdKeyHeld = false
                    vm.optKeyHeld = false
                    vm.soloKeyHeld = false
                    // An audition started by s+space keeps the temporary solo: it is its stop
                    // that will clear it, as on a normal release of the key.
                    if !auditioning { vm.endHeldSolo() }
                    if vm.heldToolKeyCode != nil {
                        vm.heldToolKeyCode = nil
                        if !vm.isToolPermanent {
                            vm.activeTool = .toolSelection
                            vm.isToolPermanent = true
                        }
                    }
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    vm.cmdKeyHeld = NSEvent.modifierFlags.contains(.command)
                    vm.optKeyHeld = NSEvent.modifierFlags.contains(.option)
                }
            }
        ]

        // The body of keyDown, taken out of the monitor so as to be callable by TWO paths:
        //  - the monitor below, when a window of ours has keyboard focus;
        //  - the end-of-chain relay of a plugin window (@see setPluginKeyFallback),
        //    for the keys the plugin did NOT consume.
        let handleKeyDown: (NSEvent) -> NSEvent? = { event in
            if isTextInput() { return event }
            // Let the sound library browser handle the arrows when it has focus
            if ExplorerFocus.shared.active,
               [123, 124, 125, 126].contains(event.keyCode) {
                return event
            }
            // A keystroke (outside auto-repeat) cancels the hold under way: the modifiers' cheat
            // sheet must not open behind a ⌘Z. The TOOL keys then restart their own hold, below.
            //
            if !event.isARepeat { cheat.schedule(nil, in: vm) }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 49:  // Space
                // 's' held → a temporary solo (⇧+space): it plays the selection/range only.
                // The audition takes the temporary layer over (didAudition): releasing 's'
                // during playback must not restore the full mix.
                if chord.keyCode != nil {
                    chord.didAudition = true
                    DispatchQueue.main.async { soloPlay() }
                    return nil
                }
                // ⇧space = pause / resume IN THE SAME PLACE (bare space, for its part, goes back to the cursor).
                if flags.contains(.shift) {
                    DispatchQueue.main.async { togglePause() }
                    return nil
                }
                DispatchQueue.main.async { togglePlayback() }
                return nil
            case 51, 117:  // Backspace / Forward Delete
                // s + ⌫: turns every toggled solo off (like Esc).
                if chord.keyCode != nil {
                    DispatchQueue.main.async { vm.clearAllSolo() }
                    return nil
                }
                // The piano roll: if notes are selected, we delete them (NOT the clip).
                // That is the 'we are in the piano roll' signal on the keyboard's side.
                if !vm.selectedMidiNoteIDs.isEmpty {
                    DispatchQueue.main.async { vm.deleteSelectedMidiNotes() }  // internal undo push
                } else if vm.timeSelection != nil {
                    DispatchQueue.main.async { vm.deleteTimeSelection() }  // internal undo push
                } else if vm.activeTool == .toolVolume {
                    DispatchQueue.main.async { vm.edit { vm.resetVolumeSelected() } }
                } else if vm.activeTool == .toolPan {
                    DispatchQueue.main.async { vm.edit { vm.resetPanSelected() } }
                } else {
                    DispatchQueue.main.async { vm.edit { vm.removeSelected() } }
                }
            case 53:  // Escape
                // An open sound object → Esc = cancel with a rollback (a design decision),
                // with priority over resetting the selection/tool.
                if vm.isEditingObject {
                    DispatchQueue.main.async { vm.cancelObjectEdit() }
                    return nil
                }
                DispatchQueue.main.async {
                    vm.selectIDs([])
                    vm.selectedMidiNoteIDs.removeAll()
                    vm.activeTool = .toolSelection
                    vm.isToolPermanent = true
                    vm.heldToolKeyCode = nil
                    vm.stemAssignIndex = nil
                    vm.clearAllSolo()   // Esc also turns every solo off (committed AND temporary)
                    // A safety net: if the 's' keyUp was lost (an app switch mid-hold),
                    // Esc gives the click its normal part back.
                    vm.soloKeyHeld = false
                }
            case 36, 76:  // Return / numpad Enter
                // 's' held → freezes into the committed solo what one is hearing temporarily (the starting
                // selection plus click adjustments). Nothing to clear first: the two layers add up, so
                // committing does not change the sound.
                if chord.keyCode != nil {
                    DispatchQueue.main.async { vm.toggleSoloForCurrentSelection() }
                    return nil
                }
                // The Cut tool active (C held or locked): Return cuts AT THE CARET (the black cursor)
                // — the object selection, otherwise the range's lanes, otherwise the caret's lane.
                if vm.activeTool == .toolCut {
                    DispatchQueue.main.async { vm.splitAtCaret() }
                    return nil
                }
                // The 'assign stem' tool active (a digit held OR locked with ⇧):
                // Return assigns the whole selection to that stem (instead of returning to zero).
                if vm.activeTool == .toolStemAssign, let n = vm.stemAssignIndex,
                   n >= 1, n <= vm.stems.count, !vm.selectedIDs.isEmpty {
                    let stemID = vm.stems[n - 1].id
                    DispatchQueue.main.async { vm.edit { vm.assignStemSelected(stemID: stemID) } }
                    return nil
                }
                DispatchQueue.main.async { returnToZero() }
                return nil
            case 115:  // Home
                DispatchQueue.main.async { returnToZero() }
                return nil
            // ← / → no longer move the playhead (± 1 s, ⌘ = start/end) and no longer serve pan
            // (moved to ↑/↓, like the knob and the inspector). The keys are still swallowed
            // (no beep and no stray scrolling).
            case 123, 124:  // ← / →
                return nil
            case 125:  // ↓
                // The piano roll: notes selected → transposition. ↓ = a semitone, ⇧↓ = an octave
                // (the visible window follows the octave shift).
                if !vm.selectedMidiNoteIDs.isEmpty, !flags.contains(.command) {
                    DispatchQueue.main.async {
                        if flags.contains(.shift) { vm.shiftSelectedMidiNotesByOctave(-1) }
                        else { vm.transposeSelectedMidiNotes(bySemitones: -1) }
                    }
                    return nil
                }
                if vm.activeTool == .toolVolume {
                    DispatchQueue.main.async { vm.edit { vm.adjustVolumeDB(-1) } }
                    return nil
                }
                // Pan: ↓ = to the left. Vertical like the knob, the wheel and the inspector's box —
                // pan is never set with ← / → any more.
                if vm.activeTool == .toolPan {
                    DispatchQueue.main.async { vm.edit { vm.adjustPanSelected(-0.1) } }
                    return nil
                }
            case 126:  // ↑
                if !vm.selectedMidiNoteIDs.isEmpty, !flags.contains(.command) {
                    DispatchQueue.main.async {
                        if flags.contains(.shift) { vm.shiftSelectedMidiNotesByOctave(1) }
                        else { vm.transposeSelectedMidiNotes(bySemitones: 1) }
                    }
                    return nil
                }
                if vm.activeTool == .toolVolume {
                    DispatchQueue.main.async { vm.edit { vm.adjustVolumeDB(1) } }
                    return nil
                }
                if vm.activeTool == .toolPan {   // ↑ = to the right
                    DispatchQueue.main.async { vm.edit { vm.adjustPanSelected(0.1) } }
                    return nil
                }
            case 18, 19, 20, 21, 22, 23, 25, 26, 28,   // the digit row (the top of the keyboard)
                 83, 84, 85, 86, 87, 88, 89, 91, 92:   // the numeric keypad
                // Stem assignment: the digit N (1 = Main, 2 = the 2nd stem…) becomes the active
                // tool. We identify the key by its PHYSICAL KEYCODE, not by the character, so as
                // to stay independent of the keyboard layout (AZERTY: the digits need ⇧;
                // QWERTY: ⇧+2 gives '@'). The tool is ALWAYS temporary (a plain hold, released
                // on keyUp by the heldToolKeyCode mechanism): the
                // ⇧ lock ('⇧+3 to stay in stem 3 mode') was removed — useless, and it
                // conflicted with editing numeric values.
                guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
                      let n = Self.stemDigit(forKeyCode: event.keyCode)
                else { return event }
                guard n <= vm.stems.count else { return nil }   // no stem N → we swallow it (no beep)
                // 's' held → it toggles stem N's solo (combinable: s+2+3+4). It takes priority over
                // stem assignment while 's' is down. The stem is ADDED to what is currently heard
                // (the temporary layer included): nothing has to be cleared any more.
                if chord.keyCode != nil {
                    if !event.isARepeat {
                        let stemID = vm.stems[n - 1].id
                        DispatchQueue.main.async { vm.toggleStemSolo(stemID) }
                    }
                    return nil
                }
                if !event.isARepeat {
                    DispatchQueue.main.async {
                        vm.stemAssignIndex = n
                        vm.activeTool = .toolStemAssign
                        vm.isToolPermanent = false
                        vm.heldToolKeyCode = event.keyCode
                    }
                    cheat.schedule(.tool(.toolStemAssign), in: vm)
                }
                return nil
            default:
                switch event.characters?.lowercased() {
                case "z":
                    if flags.contains(.command),
                       !(NSApp.keyWindow?.firstResponder is NSTextView) {
                        DispatchQueue.main.async {
                            // An open sound object: ⌘Z cancels the opening (a clean rollback of the
                            // preview machinery plus popping the session), like Esc.
                            // The generic ⌘Z would restore the items without undoing the session.
                            if !flags.contains(.shift), vm.isEditingObject {
                                vm.cancelObjectEdit()
                            } else if flags.contains(.shift) { vm.redo() }
                            else { vm.undo() }
                        }
                        return nil
                    }
                case "a":
                    if flags.contains(.command) {
                        DispatchQueue.main.async {
                            // The piano-roll context: ⌘A selects every note of the focused clip.
                            if let cid = vm.focusedMidiClipID,
                               let clip = vm.find(id: cid), clip.showsPianoRollInline {
                                vm.selectedMidiNoteIDs = Set(clip.midiNotes.map(\.id))
                            } else {
                                vm.selectAll()
                            }
                        }
                        return nil
                    }
                    // 'A' (without ⌘) = the Aux tool (formerly 'S'). ⇧ locks the tool.
                    guard !event.isARepeat else { return nil }
                    let permanent = flags.contains(.shift)
                    DispatchQueue.main.async {
                        vm.activeTool = .toolAux
                        vm.isToolPermanent = permanent
                        vm.heldToolKeyCode = permanent ? nil : event.keyCode
                    }
                    cheat.schedule(.tool(.toolAux), in: vm)
                    return nil
                case "d":
                    if flags.contains(.command) {
                        DispatchQueue.main.async {
                            if !vm.selectedMidiNoteIDs.isEmpty {
                                vm.duplicateSelectedMidiNotes()   // the piano-roll context (internal undo push)
                            } else {
                                vm.edit { vm.duplicateSelected() }
                            }
                        }
                        return nil
                    }
                case "g":
                    if flags.contains(.command) {
                        if let sel = vm.timeSelection {
                            DispatchQueue.main.async { vm.createGroupFromTimeSelection(sel) }
                        } else if !vm.selectedIDs.isEmpty {
                            DispatchQueue.main.async { vm.createGroupFromSelection(vm.selectedIDs) }
                        }
                        return nil
                    }
                // 'N' no longer toggles snapping (it is driven from the transport bar).
                // Cmd+N (New project) and Cmd+O (Open) are handled by the File menu.
                //
                // Bare J / K no longer do anything (an old 'shuttle' transport nobody ever
                // asked for: J = -1 s, K = stop and back to zero, L = +1 s). Moving the
                // playhead stays on ← / → (± 1 s, ⌘ = start/end) and Return/Home.
                //
                // L: the TRANSPORT's loop. Bare, it turns it on / off — exactly the transport
                // bar's button; with ⌘, it first sets the region on the selection (the time
                // range, otherwise the span of the selected objects) and arms it.
                case "l":
                    if flags.contains(.command) {
                        DispatchQueue.main.async { vm.setLoopRegionFromSelection() }
                        return nil
                    }
                    if flags.isDisjoint(with: [.option, .control, .shift]) {
                        DispatchQueue.main.async { vm.toggleLoopMode() }
                        return nil
                    }
                case "x":
                    if flags.contains(.command) {
                        DispatchQueue.main.async {
                            if !vm.selectedMidiNoteIDs.isEmpty {
                                vm.cutSelectedMidiNotes()         // the piano-roll context (internal undo push)
                            } else if vm.timeSelection != nil {
                                vm.edit { vm.cutTimeSelection() }
                            } else if !vm.selectedIDs.isEmpty {
                                vm.edit { vm.cutSelected() }
                            }
                        }
                        return nil
                    }
                case "c":
                    if flags.contains(.command) {
                        DispatchQueue.main.async {
                            if !vm.selectedMidiNoteIDs.isEmpty {
                                vm.copySelectedMidiNotes()       // the piano-roll context
                            } else if vm.timeSelection != nil {
                                vm.copyTimeSelection()
                            } else if !vm.selectedIDs.isEmpty {
                                vm.copySelected()
                            }
                        }
                        return nil
                    }
                    guard !event.isARepeat else { return nil }
                    let permanent = flags.contains(.shift)
                    DispatchQueue.main.async {
                        vm.activeTool = .toolCut
                        vm.isToolPermanent = permanent
                        vm.heldToolKeyCode = permanent ? nil : event.keyCode
                    }
                    cheat.schedule(.tool(.toolCut), in: vm)
                    return nil
                    // Cmd+S (Save) / Cmd+Shift+S (Save As) are handled by the File menu.
                case "r":
                    if flags.contains(.command) {
                        if vm.selectedIDs.count == 1 {
                            DispatchQueue.main.async { vm.renamingID = vm.selectedIDs.first }
                        }
                        return nil
                    }
                    if !flags.contains(.command) {
                        if flags.contains(.shift) {
                            DispatchQueue.main.async { self.applyVerticalZoom(self.blockHeight / 1.5) }
                        } else {
                            DispatchQueue.main.async { self.applyZoom(vm.pixelsPerSecond / 1.5) }
                        }
                        return nil
                    }
                case "t":
                    if !flags.contains(.command) {
                        if flags.contains(.shift) {
                            DispatchQueue.main.async { self.applyVerticalZoom(self.blockHeight * 1.5) }
                        } else {
                            DispatchQueue.main.async { self.applyZoom(vm.pixelsPerSecond * 1.5) }
                        }
                        return nil
                    }
                case "v":
                    if flags.contains(.command) {
                        // The notes take priority if we are in the piano-roll context (notes selected).
                        if !vm.selectedMidiNoteIDs.isEmpty, vm.canPasteMidiNotes {
                            DispatchQueue.main.async { vm.pasteMidiNotes() }   // internal undo push
                        } else {
                            DispatchQueue.main.async { vm.edit { vm.paste() } }
                        }
                        return nil
                    }
                    guard !event.isARepeat else { return nil }
                    let permanent = flags.contains(.shift)
                    DispatchQueue.main.async {
                        vm.activeTool = .toolVolume
                        vm.isToolPermanent = permanent
                        vm.heldToolKeyCode = permanent ? nil : event.keyCode
                    }
                    cheat.schedule(.tool(.toolVolume), in: vm)
                    return nil
                case "p", "<", ">":
                    guard !event.isARepeat else { return nil }
                    let permanent = flags.contains(.shift)
                    DispatchQueue.main.async {
                        vm.activeTool = .toolPan
                        vm.isToolPermanent = permanent
                        vm.heldToolKeyCode = permanent ? nil : event.keyCode
                    }
                    cheat.schedule(.tool(.toolPan), in: vm)
                    return nil
                case "e":
                    // 'E' = the selection tool (announced by the tool palette and by Esc).
                    // ⇧ locks it, like the other tools; holding it shows its cheat sheet.
                    if flags.contains(.command) { break }
                    guard !event.isARepeat else { return nil }
                    let permanent = flags.contains(.shift)
                    DispatchQueue.main.async {
                        vm.activeTool = .toolSelection
                        vm.isToolPermanent = permanent
                        vm.heldToolKeyCode = permanent ? nil : event.keyCode
                    }
                    cheat.schedule(.tool(.toolSelection), in: vm)
                    return nil
                case "s":
                    // 'S' is no longer a tool shortcut: the Aux tool moved to 'A'.
                    if flags.contains(.command) { break }   // Cmd+S = Save (the menu)
                    // 's' held arms the solo chords (s+Return, s+space, s+N), independently of ⇧.
                    // The release is caught on keyUp by the same keyCode.
                    chord.keyCode = event.keyCode
                    // …and, on its own, it adds the selection to what is heard for the length of the hold
                    // (a temporary solo), while opening the 'click = come in / out of what is heard' mode.
                    if !event.isARepeat {
                        chord.didAudition = false
                        DispatchQueue.main.async {
                            vm.soloKeyHeld = true
                            vm.beginHeldSolo()
                        }
                    }
                    return nil
                case "m":
                    if !flags.contains(.command) {
                        // A stem digit held (or locked) → 'N + M' mutes that bus (not the Main).
                        // It takes priority over the Volume tool's item mute.
                        if vm.activeTool == .toolStemAssign, let n = vm.stemAssignIndex,
                           n >= 1, n <= vm.stems.count, vm.stems[n - 1].id != vm.mainStemID {
                            let stemID = vm.stems[n - 1].id
                            DispatchQueue.main.async { vm.toggleStemMute(stemID) }
                            return nil
                        }
                        if vm.activeTool == .toolVolume {
                            DispatchQueue.main.async { vm.edit { vm.toggleMuteSelected() } }
                        }
                    }
                default: break
                }
            }
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                let held = event.modifierFlags.contains(.command)
                let opt  = event.modifierFlags.contains(.option)
                DispatchQueue.main.async { vm.cmdKeyHeld = held; vm.optKeyHeld = opt }
                // Modifier(s) held → the list of the matching shortcuts. Any change of the
                // combination restarts the count (⌘ then ⌘⇧ = two lists).
                if isTextInput() {
                    cheat.schedule(nil, in: vm)
                } else {
                    let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
                    cheat.schedule(mods.isEmpty ? nil : .modifiers(mods.rawValue), in: vm)
                }
                return event
            }
            if event.type == .keyUp {
                cheat.schedule(nil, in: vm)
                if chord.keyCode == event.keyCode {
                    chord.keyCode = nil
                    // The end of the 's' hold → back to normal listening, unless an audition (s+space)
                    // has taken over: it is what will clear the solo when it stops.
                    let auditioning = chord.didAudition
                    DispatchQueue.main.async {
                        vm.soloKeyHeld = false   // it closes the 'click = listen' mode
                        if !auditioning { vm.endHeldSolo() }
                    }
                    chord.didAudition = false
                }
                if let held = vm.heldToolKeyCode, held == event.keyCode {
                    DispatchQueue.main.async {
                        vm.heldToolKeyCode = nil
                        if !vm.isToolPermanent {
                            vm.activeTool = .toolSelection
                            vm.isToolPermanent = true
                        }
                    }
                }
                return event
            }

            // A plugin window has keyboard focus: it serves the key FIRST, as in any host. There is
            // no way to guess from here whether the plugin is editing text — its GUI is an opaque
            // NSView handling `keyDown:` itself, with no AppKit or JUCE field to ask (that is the case
            // of the UADXs). So we let it have the key, and whatever it does not consume comes back to
            // us through `handleKeyDown` via the JUCE relay installed on the window. Typing in the
            // plugin no longer triggers a tool; a key the plugin ignores goes on driving the timeline.
            if vm.engine?.isPluginEditorWindowKey() == true { return event }
            return handleKeyDown(event)
        }

        // The end of the chain for plugin windows: what the plugin let through.
        vm.engine?.setPluginKeyFallback { event in
            handleKeyDown(event) == nil
        }
    }

    /// The physical keyCode of a digit key → the digit 1…9 (0 unmapped: there is no stem 0).
    /// It covers the top row (layout-independent) and the numeric keypad.
    static func stemDigit(forKeyCode code: UInt16) -> Int? {
        switch code {
        case 18, 83: return 1
        case 19, 84: return 2
        case 20, 85: return 3
        case 21, 86: return 4
        case 23, 87: return 5
        case 22, 88: return 6
        case 26, 89: return 7
        case 28, 91: return 8
        case 25, 92: return 9
        default:     return nil
        }
    }

    func unregisterKeyMonitor() {
        if let m = keyMonitor        { NSEvent.removeMonitor(m); keyMonitor        = nil }
        if let m = scrollMonitor     { NSEvent.removeMonitor(m); scrollMonitor     = nil }
        if let m = magnifyMonitor    { NSEvent.removeMonitor(m); magnifyMonitor    = nil }
        if let m = rightClickMonitor { NSEvent.removeMonitor(m); rightClickMonitor = nil }
        for o in focusObservers { NotificationCenter.default.removeObserver(o) }
        focusObservers = []
        viewModel.engine?.setPluginKeyFallback(nil)   // the relay was holding on to `handleKeyDown`
    }

    // MARK: - Right-click context menu

    func registerRightClickMonitor() {
        let vm     = viewModel
        let hs     = hoverState
        let rulerH = rulerHeight
        let lg     = 4.0

        var proxies: [MenuActionProxy] = []

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let pos = hs.position, pos.y > rulerH else { return event }

            typealias HitResult = (group: SoundObject?, clip: SoundObject?, instance: SoundObject?, selectedIDs: Set<UUID>, hasClip: Bool, timeSelection: TimeSelection?, isEditingObject: Bool, colorable: SoundObject?, clickedIsEditFrame: Bool)
            let hit: HitResult = MainActor.assumeIsolated {
                let pps  = vm.pixelsPerSecond
                let bh   = vm.blockHeight
                let step = bh + lg

                // Hit-testing on the flat display list (laneEntries) → it covers top-level AND
                // nested visible objects (the actions possible inside an open group).
                let entry = vm.laneEntries.first { e in
                    let by = rulerH + Double(e.displayLane) * step
                    guard pos.y >= by && pos.y <= by + bh else { return false }
                    // An infinite bus: its surface is its whole lane (0 → the content's width).
                    if e.item.isInfiniteBus {
                        return pos.x >= 0 && pos.x <= self.contentWidth
                    }
                    let bx = e.absStart * pps
                    let bw = max(e.item.duration * pps, 2)
                    return pos.x >= bx && pos.x <= bx + bw
                }
                let grp         = entry.flatMap { $0.item.isGroup ? $0.item : nil }
                let instanceHit = entry.flatMap { $0.item.isObjectInstance ? $0.item : nil }
                let clipHit     = entry.flatMap { e -> SoundObject? in
                    if (e.item.isClip || e.item.isMIDI), !e.item.isObjectInstance { return e.item }
                    return nil
                }
                let hasClip = vm.selectedIDs.contains { id in
                    guard let item = vm.find(id: id), (item.isClip || item.isMIDI),
                          !item.isObjectInstance else { return false }
                    return true
                }
                let clickedIsEditFrame = entry.map { vm.isInObjectEditStack($0.item.id) } ?? false
                return (grp, clipHit, instanceHit, vm.selectedIDs, hasClip, vm.timeSelection,
                        vm.isEditingObject, entry?.item, clickedIsEditFrame)
            }

            let menu = NSMenu(title: "")
            menu.autoenablesItems = false   // we drive isEnabled by hand (during a bake, say)
            proxies = []

            // An OPEN sound object: closing goes through the double click and cancelling through
            // Esc / the ✕ button (a design decision). So a right click on the editing frame no
            // longer offers a dedicated entry — we simply swallow the event (a right click on a
            // child that is NOT being edited falls back on its normal menu, below).
            if hit.isEditingObject, hit.clickedIsEditFrame {
                return nil
            }

            if let group = hit.group {
                let gid = group.id
                let baking = MainActor.assumeIsolated { vm.isBaking(gid) }
                let p = MenuActionProxy { Task { @MainActor in vm.disbandGroup(id: gid) } }
                proxies.append(p)
                let item = NSMenuItem(title: L("menu.context.disbandGroup"),
                                      action: #selector(MenuActionProxy.run),
                                      keyEquivalent: "")
                item.target = p
                item.isEnabled = !baking   // the subtree is locked during the bake
                menu.addItem(item)

                if baking {
                    let bakeItem = NSMenuItem(title: L("menu.context.baking"), action: nil, keyEquivalent: "")
                    bakeItem.isEnabled = false
                    menu.addItem(bakeItem)
                } else {
                    // 'Make object': it captures the submix into a definition reusable elsewhere in the
                    // project (see EditViewModel+Objects). In a multiple selection, the option only appears
                    // if it is an identical copy-paste (→ 'Replace with N sound objects'), otherwise it is
                    // hidden (see hasClip).
                    if hit.selectedIDs.count >= 2 {
                        if let n = MainActor.assumeIsolated({ vm.uniformClipSelectionForObject() }) {
                            let pr = MenuActionProxy { Task { @MainActor in vm.replaceSelectionWithObjects() } }
                            proxies.append(pr)
                            let it = NSMenuItem(title: L("menu.context.replaceWithObjects", n),
                                                action: #selector(MenuActionProxy.run), keyEquivalent: "")
                            it.target = pr
                            menu.addItem(it)
                        }
                        MainActor.assumeIsolated { addMakeObjectsItem(menu: menu, proxies: &proxies, vm: vm) }
                    } else {
                        let ps = MenuActionProxy { Task { @MainActor in vm.makeObject(fromGroupID: gid) } }
                        proxies.append(ps)
                        let objectItem = NSMenuItem(title: L("menu.context.makeObject"),
                                                    action: #selector(MenuActionProxy.run),
                                                    keyEquivalent: "")
                        objectItem.target = ps
                        menu.addItem(objectItem)
                    }
                }
            } else if let instance = hit.instance {
                let sid = instance.id
                let baking = MainActor.assumeIsolated { vm.isBaking(sid) }
                // OPENING a sound object goes through the DOUBLE CLICK (open / close); the right click
                // only keeps 'Detach this instance' (which materialises the instance as an independent
                // editable clip/group). It stays possible while a parent is open.
                let editable = !baking
                let pd = MenuActionProxy { Task { @MainActor in vm.detachFromDefinition(placementID: sid) } }
                proxies.append(pd)
                let dItem = NSMenuItem(title: L("menu.context.detachInstance"),
                                      action: #selector(MenuActionProxy.run), keyEquivalent: "")
                dItem.target = pd
                dItem.isEnabled = editable
                menu.addItem(dItem)

                // No more manual 'Refresh' action: stale definitions are re-baked AUTOMATICALLY in the
                // background (a transitive cascade, see
                // EditViewModel+Objects.cascadeRebakeStaleFixpoint). A recompute indicator shows on
                // the instances concerned for the length of the re-bake.
            } else if let sel = hit.timeSelection {
                let p = MenuActionProxy { Task { @MainActor in vm.createGroupFromTimeSelection(sel) } }
                proxies.append(p)
                let item = NSMenuItem(title: L("menu.context.wrapInGroup"),
                                      action: #selector(MenuActionProxy.run),
                                      keyEquivalent: "")
                item.target = p
                menu.addItem(item)

                let pa = MenuActionProxy { Task { @MainActor in vm.createAuxFromTimeSelection(sel) } }
                proxies.append(pa)
                let auxItem = NSMenuItem(title: L("menu.context.createAuxClip"),
                                        action: #selector(MenuActionProxy.run),
                                        keyEquivalent: "")
                auxItem.target = pa
                menu.addItem(auxItem)

                let pm = MenuActionProxy { Task { @MainActor in vm.createMidiClipFromTimeSelection(sel) } }
                proxies.append(pm)
                let midiItem = NSMenuItem(title: L("menu.context.createMidiClip"),
                                          action: #selector(MenuActionProxy.run),
                                          keyEquivalent: "")
                midiItem.target = pm
                menu.addItem(midiItem)
            } else if hit.hasClip {
                let ids   = hit.selectedIDs
                let count = ids.count
                let label = count == 1 ? L("menu.context.groupClip") : L("menu.context.groupSelection", count)
                let p = MenuActionProxy { Task { @MainActor in vm.createGroupFromSelection(ids) } }
                proxies.append(p)
                let item = NSMenuItem(title: label,
                                      action: #selector(MenuActionProxy.run),
                                      keyEquivalent: "")
                item.target = p
                menu.addItem(item)

                // 'Create sound object' on a lone clip: a sound object is ALWAYS a group (a design
                // decision) → we first wrap the clip in a one-item group
                // (see makeObjectWrappingClip).
                if let clip = hit.clip {
                    let cid = clip.id
                    let baking = MainActor.assumeIsolated { vm.isBaking(cid) }
                    if baking {
                        let bi = NSMenuItem(title: L("menu.context.baking"), action: nil, keyEquivalent: "")
                        bi.isEnabled = false
                        menu.addItem(bi)
                    } else if count >= 2 {
                        // A multiple selection: 'Replace with N sound objects' only appears if it is a
                        // strictly identical copy-paste (the same wav, the same settings) — one definition,
                        // N linked instances. 'Create N sound objects', for its part, holds for any
                        // selection: one INDEPENDENT object per element.
                        if let n = MainActor.assumeIsolated({ vm.uniformClipSelectionForObject() }) {
                            let pr = MenuActionProxy { Task { @MainActor in vm.replaceSelectionWithObjects() } }
                            proxies.append(pr)
                            let it = NSMenuItem(title: L("menu.context.replaceWithObjects", n),
                                                action: #selector(MenuActionProxy.run), keyEquivalent: "")
                            it.target = pr
                            menu.addItem(it)
                        }
                        MainActor.assumeIsolated { addMakeObjectsItem(menu: menu, proxies: &proxies, vm: vm) }
                    } else {
                        // A lone clip → the classic creation (wrapping in a one-item group).
                        let ps = MenuActionProxy { Task { @MainActor in vm.makeObjectWrappingClip(clipID: cid) } }
                        proxies.append(ps)
                        let si = NSMenuItem(title: L("menu.context.makeObject"),
                                            action: #selector(MenuActionProxy.run), keyEquivalent: "")
                        si.target = ps
                        menu.addItem(si)
                    }
                }
            }

            // An 'infinite' bus: a top-level aux or group can lose its start/end and run over the whole
            // project (a permanent processing bus). It is toggled here, with a mirror menu in the
            // inspector's attributes.
            if let infObj = hit.colorable, infObj.canBeInfinite {
                let iid = infObj.id
                let isInf = infObj.isInfinite
                let topLevel = MainActor.assumeIsolated { vm.items.contains(where: { $0.id == iid }) }
                if topLevel {
                    if !menu.items.isEmpty { menu.addItem(.separator()) }
                    let pInf = MenuActionProxy { Task { @MainActor in vm.toggleObjectInfinite(id: iid) } }
                    proxies.append(pInf)
                    let it = NSMenuItem(title: isInf ? L("menu.context.infinite.off") : L("menu.context.infinite.on"),
                                        action: #selector(MenuActionProxy.run), keyEquivalent: "")
                    it.target = pInf
                    it.state = isInf ? .on : .off
                    menu.addItem(it)
                }
            }

            // A custom colour (a clip / MIDI clip / group / aux): a 16-colour palette, independent of
            // the stem. It paints the whole selection if the object under the cursor is part of it,
            // otherwise that object alone — the same convention as 'Group the selection' above.
            // Straight at the menu's first level (no 'Colour' submenu): one right click is enough
            // to see the palette, with no intermediate step.
            if let colorObj = hit.colorable {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                let targets: Set<UUID> = (hit.selectedIDs.contains(colorObj.id) && hit.selectedIDs.count > 1)
                    ? hit.selectedIDs : [colorObj.id]
                let currentIndex = colorObj.colorIndex

                let pReset = MenuActionProxy { Task { @MainActor in vm.setObjectColor(ids: targets, colorIndex: nil) } }
                proxies.append(pReset)
                let resetItem = NSMenuItem(title: L("menu.context.stemColor"),
                                           action: #selector(MenuActionProxy.run), keyEquivalent: "")
                resetItem.target = pReset
                resetItem.state = currentIndex == nil ? .on : .off
                menu.addItem(resetItem)
                menu.addItem(.separator())

                let swatchItem = NSMenuItem()
                swatchItem.view = ColorSwatchGridView(currentColorIndex: currentIndex) { picked in
                    Task { @MainActor in vm.setObjectColor(ids: targets, colorIndex: picked) }
                }
                menu.addItem(swatchItem)
            }

            guard !menu.items.isEmpty else { return event }
            if let window = NSApp.keyWindow {
                let screenPt = window.convertPoint(toScreen: event.locationInWindow)
                menu.popUp(positioning: nil, at: screenPt, in: nil)
            }
            return nil
        }
    }
}

// MARK: - Solo chord state (the 's' key held)

/// Remembers the 's' key's keyCode while it is physically down, so as to arm the solo chords
/// (s+Return, s+space, s+N). It lives in the keyboard monitor's closure — mutated and read
/// synchronously on the events thread, so no `DispatchQueue` latency.
final class SoloChordState {
    var keyCode: UInt16? = nil
    /// True when holding 's' has started an audition (s+space): releasing the key must then NOT
    /// clear the temporary solo, which now belongs to the playback under way (which will clear it
    /// when it stops).
    var didAudition = false
}

// MARK: - 'Create N sound objects' (a multiple selection)

/// Adds the 'Create N sound objects' item to the menu: one INDEPENDENT sound object per selected
/// element (clips, MIDI, groups mixed). Nothing to add if the selection does not lend itself to
/// it (fewer than two eligible elements, a project never saved).
@MainActor
private func addMakeObjectsItem(menu: NSMenu, proxies: inout [MenuActionProxy], vm: EditViewModel) {
    let targets = vm.objectCreationTargets()
    guard targets.count >= 2, vm.objectsFolder != nil else { return }
    guard !targets.contains(where: { vm.isBaking($0) }) else { return }
    let p = MenuActionProxy { Task { @MainActor in await vm.makeObjectsFromSelection() } }
    proxies.append(p)
    let item = NSMenuItem(title: L("menu.context.makeObjects", targets.count),
                          action: #selector(MenuActionProxy.run), keyEquivalent: "")
    item.target = p
    menu.addItem(item)
}

// MARK: - Action proxy for NSMenuItem

/// Not `private`: reused by StemStripsToolbarView for the 'stem colour' context menu.
final class MenuActionProxy: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func run() { block() }
}

// MARK: - Colour palette (a custom view inside an NSMenuItem)

/// A grid of `ObjectColorPalette` swatches inside a submenu (2 rows by default: 8 columns for
/// the 16 object/plugin hues). AppKit does not fire the standard action of an NSMenuItem
/// carrying a custom `view`: it is the view itself that detects the click and closes the menu
/// through `enclosingMenuItem` (the official pattern for colour menus, as in Notes/Mail).
/// couleur, ex. Notes/Mail).
/// Not `private`: reused by StemStripsToolbarView for the 'stem colour' context menu.
final class ColorSwatchGridView: NSView {
    private let columns: Int
    private let swatchSize: CGFloat = 18
    private let spacing: CGFloat = 6
    private let padding: CGFloat = 8
    private let palette: [Color]
    private let currentColorIndex: Int?
    private let onPick: (Int) -> Void

    override var isFlipped: Bool { true }

    /// `palette` defaults to the 16-hue palette (`ObjectColorPalette`). `columns` defaults to
    /// 8, so 2 rows for those 16 hues; to be adjusted for a palette of another size
    /// (the 10 stem hues, say, see StemStripsToolbarView).
    init(currentColorIndex: Int?,
         palette: [Color] = ObjectColorPalette.palette,
         columns: Int = 8,
         onPick: @escaping (Int) -> Void) {
        self.palette = palette
        self.columns = columns
        self.currentColorIndex = currentColorIndex
        self.onPick = onPick
        let count = palette.count
        let rows  = (count + columns - 1) / columns
        let w = padding * 2 + CGFloat(columns) * swatchSize + CGFloat(columns - 1) * spacing
        let h = padding * 2 + CGFloat(rows) * swatchSize + CGFloat(rows - 1) * spacing
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func rect(for index: Int) -> NSRect {
        let col = index % columns
        let row = index / columns
        let x = padding + CGFloat(col) * (swatchSize + spacing)
        let y = padding + CGFloat(row) * (swatchSize + spacing)
        return NSRect(x: x, y: y, width: swatchSize, height: swatchSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        for i in palette.indices {
            let r = rect(for: i)
            NSColor(palette[i]).setFill()
            NSBezierPath(ovalIn: r).fill()
            if currentColorIndex == i {
                NSColor.labelColor.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in palette.indices where rect(for: i).insetBy(dx: -2, dy: -2).contains(p) {
            onPick(i)
            enclosingMenuItem?.menu?.cancelTracking()
            return
        }
    }
}

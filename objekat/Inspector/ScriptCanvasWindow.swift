import AppKit
import SwiftUI

// MARK: - The panel

/// The window of a script canvas: a floating utility panel with a key of its own. It exists as a
/// CLASS because the app's timeline monitors have to recognise it — they are app-wide and never
/// asked which window an event came from, so with this panel key a ⌘Z would have undone the PROJECT
/// (@see TimelineKeyHandler, TimeRulerView: both let a `ScriptCanvasPanel`'s events alone).
///
/// Its own keys: ⌘Z and ⇧⌘Z walk the canvas's history, Space starts and stops the audition. Return
/// and Esc are bound to nothing — a hand that slips on Return must not Validate.
///
/// It also tells the window whether ⌘ is held (`modifiers`, UI only): the Draw / Erase switch shows
/// its flipped state while ⌘ is down. Read from `.flagsChanged` events as they pass through
/// `sendEvent`, re-read when the panel becomes key, and cleared when it stops being key (a ⌘ released
/// elsewhere would otherwise stay "held" here).
final class ScriptCanvasPanel: NSPanel {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onTogglePlay: (() -> Void)?
    var modifiers: ScriptCanvasModifiers?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged { modifiers?.set(command: event.modifierFlags.contains(.command)) }
        super.sendEvent(event)
    }

    override func becomeKey() {
        super.becomeKey()
        modifiers?.set(command: NSEvent.modifierFlags.contains(.command))
    }

    override func resignKey() {
        super.resignKey()
        modifiers?.set(command: false)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // The letter is read WITHOUT its modifiers: with ⌥ held macOS composes another character.
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if flags.contains(.shift) { onRedo?() } else { onUndo?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let held = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if held.isEmpty, event.charactersIgnoringModifiers == " " {
            onTogglePlay?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Which modifier keys the canvas window shows a state for. Today only ⌘ (the Draw / Erase flip).
/// UI only: what a gesture carries is read by the plot from the event at mouseDown.
@Observable final class ScriptCanvasModifiers {
    private(set) var commandHeld = false

    func set(command: Bool) { if commandHeld != command { commandHeld = command } }
}

/// What the hand answered when the window asked about a PENDING selection (a mode switch to Instant,
/// or Validate): apply it first, throw it away, or stay.
enum CanvasPendingChoice { case apply, ignore, cancel }

// MARK: - The windows

/// Draws the canvases scripts declare (@see ScriptCanvasStore) as floating utility panels.
///
/// The twin of `ScriptPanelWindows`, with the same two rules. Opening goes through ONE function,
/// `show`, guarded by the same condition as `hasInterface` — `--headless` opens nothing, which is
/// verifiable with no screen (`CGWindowListCopyWindowInfo` on the headless pid). And the store only
/// ever reaches a window through its hooks, which come here: `canvasOpened`, `canvasEnded`,
/// `viewportChanged`, `transportChanged`.
///
/// The ✕ of the title bar is a Cancel: the script is told, and cleans up.
@MainActor
final class ScriptCanvasWindows: NSObject, NSWindowDelegate {

    static let shared = ScriptCanvasWindows()

    static let windowSize = NSSize(width: 1100, height: 660)
    static let minimumSize = NSSize(width: 720, height: 420)

    private var windows: [UUID: ScriptCanvasPanel] = [:]
    private var pointers: [UUID: ScriptCanvasPointer] = [:]
    private var modifiers: [UUID: ScriptCanvasModifiers] = [:]
    private var closing: Set<UUID> = []
    private weak var store: ScriptCanvasStore?

    private struct WeakPlot { weak var view: ScriptCanvasPlotNSView? }
    private var plots: [UUID: WeakPlot] = [:]
    /// What each canvas plays (@see ScriptCanvasAudition). Made at the first play, never under
    /// `--headless` or `--no-audio`.
    private var auditions: [UUID: ScriptCanvasAudition] = [:]

    private static var idKey: UInt8 = 0

    /// Hooks the store up to this manager. Called once, when the view-model builds its store.
    static func attach(to store: ScriptCanvasStore) {
        shared.store = store
        store.canvasOpened = { id in shared.show(id, store: store) }
        store.canvasEnded = { id in shared.dismiss(id) }
        store.viewportChanged = { id in shared.plots[id]?.view?.viewportDidChange() }
        store.transportChanged = { id in shared.transportDidChange(id) }
    }

    /// The plot says it exists, so the viewport hook can reach it.
    func register(plot: ScriptCanvasPlotNSView, for id: UUID) {
        plots[id] = WeakPlot(view: plot)
    }

    /// Anything the transport did (a play, a stop, a seek, A / B, Delta, a new file): the plot follows
    /// the clock, and the sound follows the model.
    private func transportDidChange(_ id: UUID) {
        plots[id]?.view?.stateDidChange()
        // No audio device is touched without an interface, nor under `--no-audio`.
        let args = LaunchArguments.process
        guard !args.headless, !args.noAudio, let transport = store?.canvases[id]?.transport else { return }
        if let audition = auditions[id] {
            audition.follow(transport)
        } else if transport.playing {
            let audition = ScriptCanvasAudition()
            auditions[id] = audition
            audition.follow(transport)
        }
    }

    private func show(_ id: UUID, store: ScriptCanvasStore) {
        guard !LaunchArguments.process.headless else { return }   // = EditViewModel.hasInterface
        guard windows[id] == nil, let canvas = store.canvases[id] else { return }

        let pointer = ScriptCanvasPointer()
        pointers[id] = pointer
        let modifier = ScriptCanvasModifiers()
        modifiers[id] = modifier
        let hosting = NSHostingView(rootView: ScriptCanvasView(store: store, canvasID: id, pointer: pointer,
                                                               modifiers: modifier))
        // The window's size is ours (1100 × 660, 720 × 420 at the least); the SwiftUI content must
        // not push constraints of its own onto it.
        hosting.sizingOptions = []
        let frame = NSRect(origin: .zero, size: Self.windowSize)
        hosting.frame = frame

        let w = ScriptCanvasPanel(contentRect: frame,
                                  styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        w.title = canvas.title.isEmpty ? L("canvas.title.default") : canvas.title
        w.contentView = hosting
        w.contentMinSize = Self.minimumSize
        w.isFloatingPanel = true
        w.hidesOnDeactivate = true
        w.becomesKeyOnlyIfNeeded = false
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.modifiers = modifier
        w.onUndo = { [weak store] in if let store { _ = try? store.undo(id) } }
        w.onRedo = { [weak store] in if let store { _ = try? store.redo(id) } }
        w.onTogglePlay = { [weak store] in
            guard let store, let c = store.canvases[id] else { return }
            if c.transport.playing { try? store.stop(id) } else { try? store.play(id) }
        }
        // Beside the project window rather than over its middle, as the script panel is.
        if let main = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.isVisible }) {
            w.setFrameOrigin(NSPoint(x: main.frame.midX - frame.width / 2,
                                     y: main.frame.maxY - frame.height - 60))
        } else {
            w.center()
        }
        windows[id] = w
        objc_setAssociatedObject(w, &Self.idKey, id, .OBJC_ASSOCIATION_RETAIN)
        w.orderFrontRegardless()
        w.makeKey()
    }

    private func dismiss(_ id: UUID) {
        plots.removeValue(forKey: id)
        pointers.removeValue(forKey: id)
        modifiers.removeValue(forKey: id)
        auditions.removeValue(forKey: id)?.shutdown()
        guard let w = windows.removeValue(forKey: id) else { return }
        closing.insert(id)
        w.close()
        closing.remove(id)
    }

    /// Asks, in a sheet on the canvas window, what to do with the PENDING selection: Apply, Ignore or
    /// Cancel (stay where one was). `message` says what is about to happen (a mode switch, Validate).
    /// No window (headless, or already closed) answers Cancel, so nothing is ever done blind.
    func askAboutPending(_ id: UUID, message: String, then: @escaping (CanvasPendingChoice) -> Void) {
        guard let w = windows[id], w.attachedSheet == nil else { then(.cancel); return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("canvas.pending.title")
        alert.informativeText = message
        alert.addButton(withTitle: L("canvas.apply"))
        alert.addButton(withTitle: L("canvas.pending.ignore"))
        let cancel = alert.addButton(withTitle: L("common.cancel"))
        cancel.keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: w) { response in
            switch response {
            case .alertFirstButtonReturn: then(.apply)
            case .alertSecondButtonReturn: then(.ignore)
            default: then(.cancel)
            }
        }
    }

    /// The ✕ of the title bar is a Cancel — the script is told, and cleans up.
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? ScriptCanvasPanel,
              let id = objc_getAssociatedObject(w, &Self.idKey) as? UUID,
              !closing.contains(id) else { return }
        windows.removeValue(forKey: id)
        plots.removeValue(forKey: id)
        pointers.removeValue(forKey: id)
        modifiers.removeValue(forKey: id)
        auditions.removeValue(forKey: id)?.shutdown()
        try? store?.input(id, values: [:], press: "cancel")
    }
}

// MARK: - Its content

/// The toolbar, the plot, the sidebar of the script's own controls, the readout. All of it reads the
/// store and writes through the store's doors — the very ones `script.canvas.input` goes through —
/// and holds no state of its own but the Expert toggle (and a counter that makes a segmented control
/// read the store again after a change the store refused or the hand cancelled).
struct ScriptCanvasView: View {
    let store: ScriptCanvasStore
    let canvasID: UUID
    let pointer: ScriptCanvasPointer
    let modifiers: ScriptCanvasModifiers
    /// The window's own state: whether the `advanced` controls are drawn.
    @State private var expert = false
    /// A segmented control that was clicked but whose value did not change in the store keeps showing
    /// the clicked segment; bumping this rebuilds it from the store.
    @State private var reread = 0

    var body: some View {
        if let c = store.canvases[canvasID] {
            VStack(spacing: 0) {
                toolbar(c)
                Divider()
                HStack(spacing: 0) {
                    plot(c)
                    Divider()
                    sidebar(c).frame(width: 300)
                }
                Divider()
                readout
            }
            .frame(minWidth: ScriptCanvasWindows.minimumSize.width, minHeight: ScriptCanvasWindows.minimumSize.height)
        }
    }

    // MARK: Plot

    private func plot(_ c: ScriptCanvas) -> some View {
        ZStack {
            ScriptCanvasPlotView(store: store, canvasID: canvasID, pointer: pointer)
            if c.image == nil {
                Text(L("canvas.status.waitingImage"))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
            // The tool's cursor, over the plot's area and not over the rulers.
            Color.clear
                .padding(.leading, ScriptCanvasPlotNSView.leftRuler)
                .padding(.top, ScriptCanvasPlotNSView.topRuler)
                .cursorZone(ScriptCanvasCursors.cursor(for: c, commandHeld: modifiers.commandHeld))
                .allowsHitTesting(false)
        }
    }

    // MARK: Toolbar

    /// An SF Symbol the script named — or, when the system has none by that name, the kind's own.
    private func symbol(for tool: CanvasTool) -> String {
        NSImage(systemSymbolName: tool.icon, accessibilityDescription: nil) != nil
            ? tool.icon : CanvasTool.defaultIcon(for: tool.kind)
    }

    private func toolbar(_ c: ScriptCanvas) -> some View {
        let hasOriginal = c.transport.slots[.original] != nil
        return HStack(spacing: 10) {
            // The script's tools (there is no Hand: navigation is the wheel, ⇧-wheel, pinch and Fit).
            HStack(spacing: 4) {
                ForEach(c.tools, id: \.id) { t in
                    toolToggle(c, id: t.id, label: t.label, icon: symbol(for: t))
                }
            }
            if c.modes {
                Divider().frame(height: 18)
                modeSwitch(c)
                if c.mode == .select { polaritySwitch(c) }
            }
            Divider().frame(height: 18)
            HStack(spacing: 2) {
                Button { _ = try? store.undo(canvasID) } label: { Image(systemName: "arrow.uturn.backward") }
                    .help(L("canvas.undo.help"))
                    .disabled(!c.history.canUndo)
                Button { _ = try? store.redo(canvasID) } label: { Image(systemName: "arrow.uturn.forward") }
                    .help(L("canvas.redo.help"))
                    .disabled(!c.history.canRedo)
            }
            Divider().frame(height: 18)
            Button {
                if c.transport.playing { try? store.stop(canvasID) } else { try? store.play(canvasID) }
            } label: {
                Image(systemName: c.transport.playing ? "stop.fill" : "play.fill").frame(width: 14)
            }
            .help(c.transport.playing ? L("canvas.stop") : L("canvas.play"))
            .disabled(!hasOriginal)
            Picker(selection: Binding(get: { c.transport.listen },
                                      set: { do { try store.setListen(canvasID, $0) } catch { reread += 1 } })) {
                Text(L("canvas.listen.original")).tag(CanvasListen.original)
                Text(L("canvas.listen.result")).tag(CanvasListen.result)
                Text(L("canvas.listen.delta")).tag(CanvasListen.delta)
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 250)
            .help(L("canvas.listen.help"))
            .id(reread)
            // Choosing an empty slot is refused by the store's setter (the segment springs back).
            .disabled(!hasOriginal)
            Divider().frame(height: 18)
            Button { store.fitAll(canvasID) } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help(L("canvas.fit"))
                .disabled(c.world == nil)
            Spacer(minLength: 8)
            // The files are behind the history, or the script says it is busy (a live re-render of a
            // pending selection does not move the history: only its `busy` announces it).
            if c.showsComputing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("canvas.status.computing")).font(.caption).foregroundStyle(.secondary)
                }
            }
            // The playhead's time: read at 10 Hz, never observed — the transport is a clock.
            SwiftUI.TimelineView(.periodic(from: .now, by: 0.1)) { context in
                Text(verbatim: CanvasFormat.time(store.position(of: canvasID, at: context.date), decimals: 1))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Instantané | Sélection. Going BACK to Instant with a selection pending asks first (Apply / Ignore
    /// / Cancel); Cancel leaves the canvas in Sélection. The store refuses the switch while pending, so
    /// the answer is always applied (or discarded) BEFORE the switch.
    private func modeSwitch(_ c: ScriptCanvas) -> some View {
        Picker(selection: Binding(get: { c.mode }, set: { requestMode($0, from: c) })) {
            Text(L("canvas.mode.instant")).tag(CanvasMode.instant)
            Text(L("canvas.mode.select")).tag(CanvasMode.select)
        } label: { EmptyView() }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 190)
        .help(L("canvas.mode.help"))
        .id(reread)
    }

    private func requestMode(_ mode: CanvasMode, from c: ScriptCanvas) {
        guard mode != c.mode else { return }
        guard mode == .instant, c.history.pending > 0 else {
            do { try store.setMode(canvasID, mode) } catch { reread += 1 }
            return
        }
        let id = canvasID, store = store
        ScriptCanvasWindows.shared.askAboutPending(id, message: L("canvas.pending.mode.message")) { choice in
            switch choice {
            case .apply:
                _ = try? store.commit(id)
                try? store.setMode(id, .instant)
            case .ignore:
                _ = try? store.discardPending(id)
                try? store.setMode(id, .instant)
            case .cancel:
                break
            }
            reread += 1
        }
        reread += 1   // the segment the hand pressed springs back while the sheet is up
    }

    /// Dessiner | Effacer, Sélection only. It shows the EFFECTIVE state — the toggle flipped while ⌘ is
    /// held — and a click sets the toggle itself (to the segment clicked).
    private func polaritySwitch(_ c: ScriptCanvas) -> some View {
        Picker(selection: Binding(get: { c.effectivePolarity(commandHeld: modifiers.commandHeld) },
                                  set: { try? store.setPolarity(canvasID, $0) })) {
            Text(L("canvas.polarity.add")).tag(CanvasPolarity.add)
            Text(L("canvas.polarity.subtract")).tag(CanvasPolarity.subtract)
        } label: { EmptyView() }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 160)
        .help(L("canvas.polarity.help"))
    }

    private func toolToggle(_ c: ScriptCanvas, id: String, label: String, icon: String) -> some View {
        Toggle(isOn: Binding(get: { c.activeTool == id },
                             set: { on in if on { try? store.selectTool(canvasID, tool: id) } })) {
            // Not `Label("\(label)", …)`: a string with a hole is a LocalizedStringKey (@see CLAUDE.md).
            Label { Text(verbatim: label) } icon: { Image(systemName: icon) }
        }
        .toggleStyle(.button)
        .help(label)
    }

    // MARK: Sidebar

    private func sidebar(_ c: ScriptCanvas) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                ScriptControlsForm(controls: c.controls, values: c.values, expert: expert, labelWidth: 110,
                                   set: { id, v, coalesced in
                                       try? store.input(canvasID, values: [id: v], press: nil, coalesced: coalesced)
                                   },
                                   press: { id in try? store.input(canvasID, values: [:], press: id) })
                    .padding(12)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                // Apply ≠ Validate: it seals the pending selection into ONE history step and clears
                // it; the window stays. No shortcut (Return stays unbound).
                if c.modes && c.mode == .select {
                    Button { _ = try? store.commit(canvasID) } label: {
                        Text(L("canvas.apply")).frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(c.history.pending == 0)
                    .help(L("canvas.apply.help"))
                }
                HStack(spacing: 6) {
                    if c.busy { ProgressView().controlSize(.small) }
                    Text(verbatim: c.status)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    if c.controls.contains(where: { $0.advanced }) {
                        Button { expert.toggle() } label: {
                            Label { Text(L("scriptpanel.expert")) } icon: {
                                Image(systemName: expert ? "chevron.down" : "chevron.right")
                            }
                        }
                    }
                    if c.rememberKey != nil {
                        Button(L("scriptpanel.reset")) { try? store.input(canvasID, values: [:], press: "reset") }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button(L("common.cancel")) { try? store.input(canvasID, values: [:], press: "cancel") }
                        .tint(.red)
                    Button(L("scriptpanel.validate")) { validate(c) }
                        .disabled(c.showsComputing)
                }
            }
            .padding(12)
        }
    }

    /// Validate closes the window, so a PENDING selection asks first: Apply it (then validate), Ignore
    /// it (validate without), or Cancel (stay in the window).
    private func validate(_ c: ScriptCanvas) {
        let id = canvasID, store = store
        guard c.history.pending > 0 else {
            try? store.input(id, values: [:], press: "validate")
            return
        }
        ScriptCanvasWindows.shared.askAboutPending(id, message: L("canvas.pending.validate.message")) { choice in
            switch choice {
            case .apply:
                _ = try? store.commit(id)
                try? store.input(id, values: [:], press: "validate")
            case .ignore:
                _ = try? store.discardPending(id)
                try? store.input(id, values: [:], press: "validate")
            case .cancel:
                break
            }
        }
    }

    // MARK: Readout

    private var readout: some View {
        HStack(spacing: 18) {
            Text(verbatim: pointer.xText)
            Text(verbatim: pointer.yText)
            Text(verbatim: pointer.valueText)
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: 22)
    }
}

import Foundation
import Observation
import AVFoundation

// MARK: - A canvas a script asks the app to show

// A script that edits a SIGNAL — a spectrogram it computed, a mask it wants painted — needs more than
// a form: a resizable plot, gestures drawn on it, a history, image layers, a transport. So it
// declares a CANVAS and the app draws it (@see plan_spectral_editor.md, D1–D3). Like a panel
// (@see ScriptPanelStore) it belongs to the CONNECTION that opened it, is never persisted, has no
// undo and does not dirty the project, and it goes when that connection closes, when its object goes
// or when another document is shown.
//
// WHAT THE APP KNOWS, AND WHAT IT DOES NOT. It knows gestures (a rectangle, a stroke, a click), the
// history of those gestures (undo / redo), layers of pixels the script supplies, and playback. It
// knows NOTHING about what a gesture MEANS: each op records its geometry and a snapshot of the
// values of the controls its tool declares, and the script interprets them. There is no dB anywhere
// in this file.
//
// The exchange is the panel's: a LONG POLL on `rev`, which moves only when the hand does something
// (a value, an op, an undo, a redo, a button, Validate, Cancel). What the script writes back
// (`update`, `set_image`, `set_layer`, `set_audio`) never moves it, or the script would wake its own
// next wait for ever. A tool change, a view change and a transport change do not move it either:
// they are not the script's business.
//
// TWO REVISIONS. `rev` is the canvas's (the long poll's); `historyRev` is the history's — it moves
// each time the active list of ENTRIES changes (an entry added, sealed, discarded, an undo, a redo),
// and a script stamps what it computed from it (`set_layer {history_rev}`, `set_audio
// {history_rev}`). The app hides the trace of an op once a picture reflecting it has arrived (§2.4):
// `reflectedRev` is the largest `history_rev` the BASE image or any layer carries (revision 4: the
// base image itself can reflect the history — a script that refreshes the spectrogram to show the
// result says so with `set_image {history_rev}`), and an active op shows its raw trace iff its
// ENTRY's `activeSince > reflectedRev`.
//
// THE HISTORY IS ENTRIES (plan §9, revision 3): a `draft` (one gesture of a pending selection) or a
// `step` (a committed step: its ops and a snapshot of every hand value at the moment it was sealed).
// The pure rules live in `CanvasHistory` (ScriptCanvasHistory.swift); this file only feeds it. Two
// MODES, opt-in at `open` (`modes`): Instant (a gesture is a step at once) and Selection (a gesture is
// a draft; `commit` seals the drafts into one step; `discardPending` throws them away — the window
// asks which before a mode switch or Validate finds a selection pending). A gesture carries a
// POLARITY, add or subtract, that the app records and never interprets.
//
// HEADLESS. The store never touches a window or an audio device: the transport is a wall-clock model
// (§2.8), and the viewport a nominal plot of 1000 × 500 points. The window layer (step 8) and the
// audio layer (step 9) hang off the hooks below.

enum ScriptCanvasState: String, Sendable {
    case open, validated, cancelled, closed
}

// MARK: - Tools, ops, layers

enum CanvasToolKind: String, Sendable {
    case rect, stroke, point
}

/// A gesture the script offers. There is no Hand any more: navigation is the wheel, ⇧-wheel, the
/// pinch and Fit, and with no tool declared a left click in the plot does nothing.
struct CanvasTool: Equatable, Sendable {
    let id: String
    let kind: CanvasToolKind
    /// The script's own text, already localised.
    let label: String
    /// An SF Symbol name — the script's, or the kind's own when it gave none. An unknown name is
    /// the window's to fall back on.
    let icon: String
    /// The ids of the hand-value controls snapshotted into each op.
    let params: [String]
    /// A `stroke` tool's: the `number` control giving the diameter in screen points.
    let sizeControl: String?

    static func defaultIcon(for kind: CanvasToolKind) -> String {
        switch kind {
        case .rect: return "rectangle.dashed"
        case .stroke: return "scribble"
        case .point: return "smallcircle.filled.circle"
        }
    }
}

/// What a gesture drew, in DATA units (and, for a stroke, the brush in warped units).
enum CanvasOpShape: Equatable {
    case rect(x0: Double, x1: Double, y0: Double, y1: Double)
    /// `sizePt` is the diameter in screen points; `sizeX` / `sizeY` the same diameter in WARPED
    /// units, frozen when the gesture starts (`sizePt / pointsPerX`, `sizePt / pointsPerY`).
    case stroke(points: [CanvasPoint], sizePt: Double, sizeX: Double, sizeY: Double)
    case point(x: Double, y: Double)
}

/// Add or subtract: a property of the gesture, frozen when it starts. The app records it and does not
/// know what "subtract" does; always `add` in Instant mode.
enum CanvasPolarity: String, Sendable {
    case add, subtract
}

/// Instant: each gesture is applied at once (one history step). Selection: gestures build a pending
/// selection that `commit` seals into one step.
enum CanvasMode: String, Sendable {
    case instant, select
}

struct CanvasOp: Equatable {
    /// Monotonic per canvas, from 1; an id is never reused, even after the op has been undone and
    /// dropped by a new one.
    let id: Int
    let tool: String
    let shape: CanvasOpShape
    /// The values of the tool's declared controls AT THE MOMENT of the gesture. The app attaches no
    /// meaning to them.
    let params: [String: JSONValue]
    let polarity: CanvasPolarity

    var kind: CanvasToolKind {
        switch shape {
        case .rect: return .rect
        case .stroke: return .stroke
        case .point: return .point
        }
    }
}

/// An image the script laid over the base. It always covers the world rectangle exactly (the app
/// scales it), is drawn above the base in ascending `z`, and may say which history revision it
/// reflects.
struct CanvasLayer {
    let id: String
    var image: ScriptCanvasImage
    var z: Int
    var opacity: Double
    var historyRev: Int?
}

/// An image tied to an audio slot, with the history revision it reflects (nil = none claimed).
struct CanvasSlotImage {
    var image: ScriptCanvasImage
    var historyRev: Int?
}

// MARK: - Transport

enum CanvasSlot: String, CaseIterable, Sendable {
    case original, result, delta
}

/// The ONE three-state switch: what the ear hears. Each case is the slot of the same name.
enum CanvasListen: String, CaseIterable, Sendable {
    case original, result, delta
}

/// The transport model (§2.8), the same one for the store, the window and the headless clock.
/// While playing, `position = anchorPosition + (now − anchorSince)`; stopped, it is the caret.
struct ScriptCanvasTransport {
    var playing = false
    /// Where playback restarts, and where a stop returns to.
    var caret = 0.0
    var anchorPosition = 0.0
    var anchorSince: Date? = nil
    var listen: CanvasListen = .original
    /// The path of each slot that holds a file.
    var slots: [CanvasSlot: String] = [:]
    /// The length, in seconds, of each file.
    var durations: [CanvasSlot: Double] = [:]
    /// The x value at which the files' sample 0 plays.
    var offset = 0.0
    /// The history revision the files reflect; nil until the script says.
    var audioHistoryRev: Int? = nil

    /// Where playback ends: the longest file, placed at `offset`.
    var end: Double {
        guard let longest = durations.values.max() else { return 0 }
        return Swift.max(0, offset + longest)
    }

    func position(at now: Date) -> Double {
        guard playing, let since = anchorSince else { return caret }
        return Swift.min(end, Swift.max(0, anchorPosition + now.timeIntervalSince(since)))
    }
}

// MARK: - The canvas

/// One entry of a canvas's history: a draft or a step (@see CanvasHistory).
typealias CanvasHistoryEntry = CanvasEntry<CanvasOp, [String: JSONValue]>

struct ScriptCanvas {
    let id: UUID
    let owner: UUID
    let objectID: UUID?
    var title: String
    var controls: [ScriptPanelControl]
    var values: [String: JSONValue]
    var tools: [CanvasTool]
    /// A tool id; nil when the script declared none.
    var activeTool: String?
    /// Opt-in at `open`: the canvas offers the two modes and subtract. Without it, Instant only.
    var modes = false
    var mode: CanvasMode = .instant
    /// The Draw / Erase TOGGLE's state (the ⌘ flip is the window's and is not in it). `add` in Instant.
    var polarity: CanvasPolarity = .add
    var rev = 0
    var state: ScriptCanvasState = .open
    var pendingEvents: [String] = []
    var status = ""
    var busy = false
    var rememberKey: String? = nil
    var declared: [String: JSONValue] = [:]

    // History: entries (@see CanvasHistory); ops keep their own ids.
    var history = CanvasHistory<CanvasOp, [String: JSONValue]>()
    var nextOpID = 1

    // What is drawn
    var image: ScriptCanvasImage? = nil
    /// The history revision the BASE image reflects (`set_image`'s `history_rev`); nil = none claimed.
    var imageHistoryRev: Int? = nil
    /// An image per audio slot (`set_image {slot}`): the picture that goes with what is HEARD. The base
    /// image above is the fallback for a slot with none (and the result's, for the spectral editor).
    var slotImages: [CanvasSlot: CanvasSlotImage] = [:]
    /// The unit of the base image's values, for the pointer readout.
    var valueUnit = ""
    var world: CanvasWorld? = nil
    var layers: [CanvasLayer] = []

    var transport = ScriptCanvasTransport()

    /// The largest `history_rev` the base image, a slot image or any layer carries, −1 when none does.
    var reflectedRev: Int {
        (layers.compactMap(\.historyRev) + slotImages.values.compactMap(\.historyRev)
            + [imageHistoryRev].compactMap { $0 }).max() ?? -1
    }

    /// The image the plot draws: the one of the slot being HEARD when the script gave one, else the base.
    var displayedImage: ScriptCanvasImage? {
        slotImages[CanvasSlot(rawValue: transport.listen.rawValue)!]?.image ?? image
    }

    /// The history's revision: moves each time the active list of entries changes.
    var historyRev: Int { history.rev }

    /// The ops whose raw trace is still visible: those of the active entries the script has not yet
    /// reflected, in order.
    var unreflectedOps: [CanvasOp] {
        history.activeEntries(since: reflectedRev).flatMap(\.ops)
    }

    var unreflectedOpIDs: [Int] { unreflectedOps.map(\.id) }

    /// True while the files the script supplied are behind the history.
    var isComputing: Bool {
        guard let audio = transport.audioHistoryRev else { return false }
        return historyRev > audio
    }

    /// What the toolbar's "Calcul…" shows: the files are behind the history, OR the script said it is
    /// busy. A live re-render of a pending selection (a gain moved) does not move the history, so
    /// only the script's own `busy` can announce it (plan §9.2).
    var showsComputing: Bool { busy || isComputing }

    /// The polarity a gesture drawn NOW carries: the Draw / Erase toggle's, flipped while ⌘ is held.
    /// Always `add` in Instant (there is no Erase there). `commandHeld` is the window's to read
    /// (the plot reads the modifier flags at mouseDown and freezes the answer for the gesture).
    func effectivePolarity(commandHeld: Bool) -> CanvasPolarity {
        guard mode == .select else { return .add }
        guard commandHeld else { return polarity }
        return polarity == .add ? .subtract : .add
    }
}

// MARK: - The store

@Observable final class ScriptCanvasStore {

    private(set) var canvases: [UUID: ScriptCanvas] = [:]

    /// Set by the window layer (`ScriptCanvasWindows`): called after a canvas appears / after one
    /// stops being open. The store itself knows nothing about windows.
    @ObservationIgnored var canvasOpened: ((UUID) -> Void)?
    @ObservationIgnored var canvasEnded: ((UUID) -> Void)?
    /// The view moved (a script-side change of world, `view` from the hand's door, a fit).
    @ObservationIgnored var viewportChanged: ((UUID) -> Void)?
    /// Anything the audio layer must follow: play, stop, seek, a listen change, a slot.
    @ObservationIgnored var transportChanged: ((UUID) -> Void)?
    /// Starting a canvas's playback stops the PROJECT's (set by the view-model).
    @ObservationIgnored var stopProjectTransport: (() -> Void)?

    /// A headless canvas has no window to measure: this is the plot it nominally has.
    static let nominalWidth = 1000.0
    static let nominalHeight = 500.0
    static let maxLayers = 8
    static let maxStrokePoints = 20_000
    static let minStrokePoints = 2

    /// The hand's slider moves at screen speed; the script needs the last value, not 120 of them a
    /// second. `rev` is bumped at most this often, with a trailing bump so the FINAL value is
    /// never left unannounced.
    static let coalesceInterval: TimeInterval = 1.0 / 30.0
    @ObservationIgnored private var lastBump: [UUID: Date] = [:]
    @ObservationIgnored private var trailing: Set<UUID> = []
    /// The visible window of each canvas. Not observed: the plot redraws on `viewportChanged`.
    @ObservationIgnored private var viewports: [UUID: CanvasViewport] = [:]

    private static func bad(_ m: String) -> CommandError { CommandError(code: .bad_params, message: m) }
    private static func invalid(_ m: String) -> CommandError { CommandError(code: .invalid_state, message: m) }

    // MARK: What a canvas remembers besides its values — the mode and the tool (plan §10)

    /// The ONE place that names the storage of a canvas's own state (a panel has none): the panel
    /// memory's, under `<key>.canvas`, so the hand's Reset (which erases `<key>`) leaves it alone.
    static func stateMemoryKey(_ key: String) -> String { key + ".canvas" }

    /// Keeps the mode (only when the canvas has modes) and the active tool of a remembering canvas.
    private func rememberState(_ c: ScriptCanvas) {
        guard let key = c.rememberKey else { return }
        var raw: [String: JSONValue] = [:]
        if c.modes { raw["mode"] = .string(c.mode.rawValue) }
        if let tool = c.activeTool { raw["tool"] = .string(tool) }
        ScriptPanelMemory.save(Self.stateMemoryKey(key), raw)
    }

    /// Puts onto a canvas about to open the mode and tool it was left on, when they still fit.
    static func applyRememberedState(to canvas: inout ScriptCanvas) {
        guard let key = canvas.rememberKey else { return }
        let stored = ScriptPanelMemory.load(stateMemoryKey(key))
        let fit = CanvasRememberedState.restored(
            CanvasRememberedState(mode: stored["mode"]?.stringValue, tool: stored["tool"]?.stringValue),
            modesEnabled: canvas.modes, toolIDs: canvas.tools.map(\.id))
        if let m = fit.mode, let mode = CanvasMode(rawValue: m) { canvas.mode = mode }
        if let t = fit.tool { canvas.activeTool = t }
    }

    // MARK: Open / close

    /// One canvas per connection: a second one replaces the first.
    func open(_ canvas: ScriptCanvas) {
        for old in canvases.values where old.owner == canvas.owner { remove(old.id, reason: .closed) }
        canvases[canvas.id] = canvas
        canvasOpened?(canvas.id)
    }

    /// Ends a canvas: `state` says how (closed by the script or by the app), and the record stays
    /// readable until its owner's connection goes, so a script can still be told `closed`.
    /// Ending a canvas stops its playback.
    func end(_ id: UUID, as state: ScriptCanvasState) {
        guard var c = canvases[id], c.state == .open else { return }
        c.state = state
        c.rev += 1
        Self.stopPlayback(&c.transport)
        canvases[id] = c
        transportChanged?(id)
        canvasEnded?(id)
    }

    private func remove(_ id: UUID, reason: ScriptCanvasState) {
        end(id, as: reason)
        canvases.removeValue(forKey: id)
        viewports.removeValue(forKey: id)
        lastBump.removeValue(forKey: id)
        trailing.remove(id)
    }

    func connectionClosed(_ owner: UUID) {
        for c in canvases.values where c.owner == owner { remove(c.id, reason: .closed) }
    }

    func closeWhereObjectGone(exists: (UUID) -> Bool) {
        for c in canvases.values where c.state == .open {
            if let o = c.objectID, !exists(o) { end(c.id, as: .closed) }
        }
    }

    func closeAll(reason: ScriptCanvasState) {
        for c in canvases.values { end(c.id, as: reason) }
    }

    // MARK: Lookup

    private func canvas(_ id: UUID) throws -> ScriptCanvas {
        guard let c = canvases[id] else {
            throw CommandError(code: .not_found, message: "no canvas \(id.uuidString)")
        }
        return c
    }

    /// A canvas that is still open — what every hand-side and script-side write needs.
    private func openCanvas(_ id: UUID) throws -> ScriptCanvas {
        let c = try canvas(id)
        guard c.state == .open else { throw Self.invalid("canvas is \(c.state.rawValue)") }
        return c
    }

    // MARK: What the hand does — values, buttons

    /// Applies what a hand (the window, or `script.canvas.input`) set. Unknown ids and kinds that do
    /// not match are refused; a number is clamped to its range. Throws before anything is stored, so
    /// a refused batch changes nothing. `coalesced`: a slider drag — the values land at once, the
    /// `rev` at most 30 times a second.
    func input(_ id: UUID, values: [String: JSONValue], press: String?, coalesced: Bool = false) throws {
        guard var c = canvases[id] else {
            throw CommandError(code: .not_found, message: "no canvas \(id.uuidString)")
        }
        guard c.state == .open else { throw Self.invalid("canvas is \(c.state.rawValue)") }
        try ScriptControls.applyHand(values, controls: c.controls, into: &c.values)
        // A canvas remembers LIVE (plan §10): every change of a hand value is kept for the next
        // opening, whatever way the window ends. A Reset press below erases it again.
        if let key = c.rememberKey, !values.isEmpty, press != "reset" {
            ScriptControls.remember(key, controls: c.controls, values: c.values)
        }
        var immediate = !coalesced
        var ended = false
        if let press {
            switch press {
            case "validate":
                c.state = .validated; immediate = true; ended = true
            case "cancel":
                c.state = .cancelled; immediate = true; ended = true
            case "reset" where c.rememberKey != nil:
                // Back to what the script DECLARED; the script sees it as a hand's input (rev moves).
                ScriptControls.reset(c.rememberKey!, controls: c.controls, declared: c.declared,
                                     into: &c.values)
                immediate = true
            default:
                guard let control = c.controls.first(where: { $0.id == press }), control.kind == .button else {
                    throw Self.bad("no button '\(press)'")
                }
                c.pendingEvents.append(press)
                immediate = true
            }
        }
        if ended { Self.stopPlayback(&c.transport) }
        canvases[id] = c
        if immediate { bump(id) } else { bumpCoalesced(id) }
        if ended {
            transportChanged?(id)
            canvasEnded?(id)
        }
    }

    private func bump(_ id: UUID) {
        guard canvases[id] != nil else { return }
        canvases[id]!.rev += 1
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
        var c = try canvas(id)
        if let status { c.status = status }
        if let busy { c.busy = busy }
        try ScriptControls.applyLabels(labels, to: &c.controls)
        try ScriptControls.applyScript(values, controls: c.controls, into: &c.values)
        canvases[id] = c
    }

    /// The answer of `script.canvas.get` / `wait`: reading drains the button events (and settles a
    /// transport that has run past its end).
    func read(_ id: UUID) throws -> ScriptCanvas {
        _ = try canvas(id)
        settleTransport(id)
        var c = canvases[id]!
        let snapshot = c
        if !c.pendingEvents.isEmpty { c.pendingEvents = []; canvases[id] = c }
        return snapshot
    }

    // MARK: The base image and the layers — never move `rev`

    /// Sets the BASE image and the world. If the axes are unchanged the view and the layers are
    /// kept; otherwise the view is refitted and every layer is dropped.
    /// `historyRev`: the history revision the new image reflects (a script that redraws the spectrogram
    /// to show the RESULT), counted with the layers' when the app decides which traces to hide; nil = none.
    func setImage(_ id: UUID, image: ScriptCanvasImage, world: CanvasWorld, valueUnit: String,
                  historyRev: Int? = nil) throws {
        var c = try openCanvas(id)
        let sameWorld = c.world?.isSame(as: world) ?? false
        c.image = image
        c.imageHistoryRev = historyRev
        c.valueUnit = valueUnit
        c.world = world
        if !sameWorld { c.layers = []; c.slotImages = [:] }
        canvases[id] = c
        if !sameWorld {
            let old = viewports[id]
            viewports[id] = CanvasViewport.fit(world: world, width: old?.width ?? Self.nominalWidth,
                                               height: old?.height ?? Self.nominalHeight)
            viewportChanged?(id)
        }
    }

    /// Sets, replaces or removes (`image` nil) the picture of an audio slot. It covers the SAME world as
    /// the base image (no axes of its own), so a base image must exist. What the plot draws follows the
    /// slot being heard (@see ScriptCanvas.displayedImage): switching is a redraw, no round trip.
    func setSlotImage(_ id: UUID, slot: CanvasSlot, image: ScriptCanvasImage?, historyRev: Int?) throws {
        var c = try openCanvas(id)
        guard c.image != nil else { throw Self.invalid("no base image yet (script.canvas.set_image first)") }
        if let image { c.slotImages[slot] = CanvasSlotImage(image: image, historyRev: historyRev) }
        else { c.slotImages.removeValue(forKey: slot) }
        canvases[id] = c   // like `setImage`: the observing view redraws
    }

    /// Adds or replaces a layer, or removes it (`image` nil). An existing id keeps its z and
    /// opacity unless they are given; its `historyRev` is always the one given.
    @discardableResult
    func setLayer(_ id: UUID, layer: String, image: ScriptCanvasImage?, z: Int?, opacity: Double?,
                  historyRev: Int?) throws -> [CanvasLayer] {
        var c = try openCanvas(id)
        guard c.image != nil else { throw Self.invalid("no base image yet (script.canvas.set_image first)") }
        if let opacity, !(opacity.isFinite && opacity >= 0 && opacity <= 1) {
            throw Self.bad("opacity is 0…1")
        }
        let index = c.layers.firstIndex(where: { $0.id == layer })
        if let image {
            if let i = index {
                c.layers[i].image = image
                if let z { c.layers[i].z = z }
                if let opacity { c.layers[i].opacity = opacity }
                c.layers[i].historyRev = historyRev
            } else {
                guard c.layers.count < Self.maxLayers else {
                    throw Self.bad("at most \(Self.maxLayers) layers")
                }
                c.layers.append(CanvasLayer(id: layer, image: image, z: z ?? 0,
                                            opacity: opacity ?? 1, historyRev: historyRev))
            }
        } else if let i = index {
            c.layers.remove(at: i)
        }
        canvases[id] = c
        return Self.layersInDrawOrder(c.layers)
    }

    /// Ascending z; layers of the same z keep the order they were laid in.
    static func layersInDrawOrder(_ layers: [CanvasLayer]) -> [CanvasLayer] {
        layers.enumerated().sorted { a, b in
            a.element.z != b.element.z ? a.element.z < b.element.z : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Audio slots — never move `rev`

    /// Sets the three files. A key present with nil CLEARS the slot, an absent key keeps it. Every
    /// file is opened (header only) before anything is stored, so a refused call changes nothing.
    /// `listen` (optional) chooses the slot heard, like the hand's switch: it must hold a file once the
    /// call is applied (`invalid_state` otherwise, nothing stored). A script says it once, with its first
    /// files, to open on the slot it wants heard.
    func setAudio(_ id: UUID, slots: [CanvasSlot: String?], offset: Double?, historyRev: Int?,
                  listen: CanvasListen? = nil) throws {
        var c = try openCanvas(id)
        var lengths: [CanvasSlot: Double] = [:]
        for (slot, path) in slots {
            if let path { lengths[slot] = try Self.audioDuration(path: path) }
        }
        if let offset, !offset.isFinite { throw Self.bad("offset must be a finite number") }
        if let listen {
            let target = CanvasSlot(rawValue: listen.rawValue)!
            let filled = slots[target].map { $0 != nil } ?? (c.transport.slots[target] != nil)
            guard filled else { throw Self.invalid("the \(listen.rawValue) slot would be empty") }
        }
        for (slot, path) in slots {
            if let path {
                c.transport.slots[slot] = path
                c.transport.durations[slot] = lengths[slot]
            } else {
                c.transport.slots.removeValue(forKey: slot)
                c.transport.durations.removeValue(forKey: slot)
            }
        }
        if let offset { c.transport.offset = offset }
        if let historyRev { c.transport.audioHistoryRev = historyRev }
        if let listen { c.transport.listen = listen }
        // What can no longer be heard falls back: a cleared `result` or `delta` being heard to the
        // original, a cleared original to silence.
        if c.transport.listen != .original, c.transport.slots[CanvasSlot(rawValue: c.transport.listen.rawValue)!] == nil {
            c.transport.listen = .original
        }
        if c.transport.slots[.original] == nil { Self.stopPlayback(&c.transport) }
        canvases[id] = c
        transportChanged?(id)
    }

    private static func audioDuration(path: String) throws -> Double {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CommandError(code: .not_found, message: "file not found: \(path)")
        }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              file.processingFormat.sampleRate > 0 else {
            throw bad("cannot read audio file \(path)")
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: Tools and the view — never move `rev`

    func selectTool(_ id: UUID, tool: String) throws {
        var c = try openCanvas(id)
        guard c.tools.contains(where: { $0.id == tool }) else {
            throw Self.bad("no tool '\(tool)'")
        }
        c.activeTool = tool
        canvases[id] = c
        rememberState(c)
    }

    /// The visible window, in a plot of the size the window gave it (nominal when headless). nil
    /// until the canvas has a world.
    func viewport(_ id: UUID) -> CanvasViewport? {
        guard let c = canvases[id], let world = c.world else { return nil }
        return viewports[id] ?? CanvasViewport.fit(world: world, width: Self.nominalWidth,
                                                   height: Self.nominalHeight)
    }

    /// The window's own door (a pan, a zoom, a resize). Clamped to the world.
    func setViewport(_ id: UUID, _ viewport: CanvasViewport) {
        guard let world = canvases[id]?.world else { return }
        viewports[id] = viewport.clamped(in: world)
        viewportChanged?(id)
    }

    /// `input`'s `view`: a window in DATA units, kept at the plot's current size and clamped.
    func setView(_ id: UUID, x0: Double, x1: Double, y0: Double, y1: Double) throws {
        let c = try openCanvas(id)
        guard let world = c.world, let current = viewport(id) else { throw Self.invalid("no world yet") }
        guard [x0, x1, y0, y1].allSatisfy(\.isFinite) else { throw Self.bad("view bounds must be finite numbers") }
        guard x0 < x1, y0 < y1 else { throw Self.bad("view needs x0 < x1 and y0 < y1") }
        if world.x.mapping == .log && x0 <= 0 { throw Self.bad("x0 must be > 0 on a log axis") }
        if world.y.mapping == .log && y0 <= 0 { throw Self.bad("y0 must be > 0 on a log axis") }
        var v = current
        v.x0w = world.x.warp(x0); v.x1w = world.x.warp(x1)
        v.y0w = world.y.warp(y0); v.y1w = world.y.warp(y1)
        setViewport(id, v)
    }

    func fitAll(_ id: UUID) {
        guard let world = canvases[id]?.world, let current = viewport(id) else { return }
        setViewport(id, CanvasViewport.fit(world: world, width: current.width, height: current.height))
    }

    // MARK: Modes and polarity — never move `rev` (like a tool, they are not the script's business:
    // the entries already say everything it needs)

    /// Switches mode. Refused (`invalid_state`) without `modes`, and while a selection is PENDING:
    /// the window asks first (Apply = `commit`, Ignore = `discardPending`) and switches after. Going
    /// to Instant puts the polarity toggle back to `add`.
    func setMode(_ id: UUID, _ mode: CanvasMode) throws {
        let c = try openCanvas(id)
        guard c.modes else { throw Self.invalid("this canvas has no modes (open with modes: true)") }
        guard c.mode != mode else { return }
        guard c.history.pending == 0 else {
            throw Self.invalid("a selection is pending (commit it or discard it first)")
        }
        canvases[id]!.mode = mode
        if mode == .instant { canvases[id]!.polarity = .add }
        rememberState(canvases[id]!)
    }

    /// The Draw / Erase toggle. `subtract` is refused in Instant mode.
    func setPolarity(_ id: UUID, _ polarity: CanvasPolarity) throws {
        let c = try openCanvas(id)
        if polarity == .subtract && c.mode == .instant {
            throw Self.invalid("subtract needs the selection mode")
        }
        canvases[id]!.polarity = polarity
    }

    // MARK: The history — each of these moves `rev` when it changes something

    private func tool(for kind: CanvasToolKind, in c: ScriptCanvas) throws -> CanvasTool {
        if let active = c.tools.first(where: { $0.id == c.activeTool }), active.kind == kind { return active }
        guard let t = c.tools.first(where: { $0.kind == kind }) else {
            throw Self.invalid("no \(kind.rawValue) tool")
        }
        return t
    }

    private func snapshot(of tool: CanvasTool, in c: ScriptCanvas) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in tool.params { if let v = c.values[key] { out[key] = v } }
        return out
    }

    /// The polarity a gesture will carry: the one given (the window's, with the ⌘ flip), else the
    /// toggle's in Selection mode, else `add`. An explicit `subtract` in Instant mode is refused.
    private func resolvePolarity(_ given: CanvasPolarity?, in c: ScriptCanvas) throws -> CanvasPolarity {
        if let given {
            if given == .subtract && c.mode == .instant { throw Self.invalid("subtract needs the selection mode") }
            return given
        }
        return c.mode == .select ? c.polarity : .add
    }

    /// Instant: one step of one op, `params` = every hand value now. Selection: a draft. Either way
    /// the redo tail goes and the history moves.
    private func append(_ id: UUID, shape: CanvasOpShape, tool: CanvasTool, polarity: CanvasPolarity) {
        var c = canvases[id]!
        let op = CanvasOp(id: c.nextOpID, tool: tool.id, shape: shape, params: snapshot(of: tool, in: c),
                          polarity: polarity)
        switch c.mode {
        case .instant:
            // Cannot be refused: Instant never holds a pending selection (a mode switch needs none).
            guard c.history.appendStep(ops: [op], params: ScriptControls.handValues(c.controls, c.values)) else { return }
        case .select:
            c.history.appendDraft(op)
        }
        c.nextOpID += 1
        canvases[id] = c
        bump(id)
    }

    /// A rectangle in data units: sorted, clamped to the world. Zero area adds nothing. `polarity`
    /// nil = the toggle's (Selection) or `add` (Instant).
    @discardableResult
    func addRect(_ id: UUID, x0: Double, x1: Double, y0: Double, y1: Double,
                 polarity: CanvasPolarity? = nil) throws -> Bool {
        let c = try openCanvas(id)
        guard let world = c.world else { throw Self.invalid("no world yet") }
        let t = try tool(for: .rect, in: c)
        let pol = try resolvePolarity(polarity, in: c)
        guard [x0, x1, y0, y1].allSatisfy(\.isFinite) else { throw Self.bad("rect bounds must be finite numbers") }
        let ax0 = world.x.clamp(Swift.min(x0, x1)), ax1 = world.x.clamp(Swift.max(x0, x1))
        let ay0 = world.y.clamp(Swift.min(y0, y1)), ay1 = world.y.clamp(Swift.max(y0, y1))
        guard ax0 < ax1, ay0 < ay1 else { return false }
        append(id, shape: .rect(x0: ax0, x1: ax1, y0: ay0, y1: ay1), tool: t, polarity: pol)
        return true
    }

    /// A stroke: 2…20000 points in data units, kept as given. `scale` is points per WARPED unit
    /// (the window's, frozen when the gesture started; the current viewport's when absent). A path
    /// shorter than one point on screen adds nothing.
    @discardableResult
    func addStroke(_ id: UUID, points: [CanvasPoint], scale: (x: Double, y: Double)? = nil,
                   polarity: CanvasPolarity? = nil) throws -> Bool {
        let c = try openCanvas(id)
        guard let world = c.world, let vp = viewport(id) else { throw Self.invalid("no world yet") }
        let t = try tool(for: .stroke, in: c)
        let pol = try resolvePolarity(polarity, in: c)
        guard points.count >= Self.minStrokePoints, points.count <= Self.maxStrokePoints else {
            throw Self.bad("a stroke has \(Self.minStrokePoints) to \(Self.maxStrokePoints) points")
        }
        for p in points {
            guard p.x.isFinite, p.y.isFinite else { throw Self.bad("stroke points must be finite numbers") }
            if world.x.mapping == .log && p.x <= 0 { throw Self.bad("stroke x must be > 0 on a log axis") }
            if world.y.mapping == .log && p.y <= 0 { throw Self.bad("stroke y must be > 0 on a log axis") }
        }
        let sx = scale?.x ?? vp.pointsPerX
        let sy = scale?.y ?? vp.pointsPerY
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { throw Self.bad("view_scale must be > 0") }
        // Screen length of the path: warped steps times points per warped unit.
        var length = 0.0
        for i in 1..<points.count {
            let dx = (world.x.warp(points[i].x) - world.x.warp(points[i - 1].x)) * sx
            let dy = (world.y.warp(points[i].y) - world.y.warp(points[i - 1].y)) * sy
            length += (dx * dx + dy * dy).squareRoot()
        }
        guard length >= 1 else { return false }
        // The diameter, in points, from the control the tool names (1…1000).
        var sizePt = 32.0
        if let key = t.sizeControl, let v = c.values[key]?.doubleValue { sizePt = v }
        sizePt = Swift.min(1000, Swift.max(1, sizePt))
        append(id, shape: .stroke(points: points, sizePt: sizePt, sizeX: sizePt / sx, sizeY: sizePt / sy),
               tool: t, polarity: pol)
        return true
    }

    @discardableResult
    func addPoint(_ id: UUID, x: Double, y: Double, polarity: CanvasPolarity? = nil) throws -> Bool {
        let c = try openCanvas(id)
        guard let world = c.world else { throw Self.invalid("no world yet") }
        let t = try tool(for: .point, in: c)
        let pol = try resolvePolarity(polarity, in: c)
        guard x.isFinite, y.isFinite else { throw Self.bad("point must be finite numbers") }
        if world.x.mapping == .log && x <= 0 { throw Self.bad("point x must be > 0 on a log axis") }
        if world.y.mapping == .log && y <= 0 { throw Self.bad("point y must be > 0 on a log axis") }
        append(id, shape: .point(x: x, y: y), tool: t, polarity: pol)
        return true
    }

    /// "Apply": seals the pending selection into ONE step, `params` = every hand value NOW. False
    /// (`rev` unmoved) with nothing pending.
    @discardableResult
    func commit(_ id: UUID) throws -> Bool {
        let c = try openCanvas(id)
        guard canvases[id]!.history.commit(params: ScriptControls.handValues(c.controls, c.values)) else {
            return false
        }
        bump(id)
        return true
    }

    /// "Ignore": throws the pending selection away (nothing of it can be redone). False with nothing
    /// pending. The window offers it beside `commit` when a mode switch or Validate finds a selection
    /// pending.
    @discardableResult
    func discardPending(_ id: UUID) throws -> Bool {
        _ = try openCanvas(id)
        guard canvases[id]!.history.discardPending() else { return false }
        bump(id)
        return true
    }

    /// One entry back. At the start of the history it is a no-op (false, `rev` unmoved).
    @discardableResult
    func undo(_ id: UUID) throws -> Bool {
        _ = try openCanvas(id)
        guard canvases[id]!.history.undo() else { return false }
        bump(id)
        return true
    }

    /// One entry forward: it becomes active AGAIN, so its trace shows until the script reflects it.
    /// At the end of the history it is a no-op.
    @discardableResult
    func redo(_ id: UUID) throws -> Bool {
        _ = try openCanvas(id)
        guard canvases[id]!.history.redo() else { return false }
        bump(id)
        return true
    }

    func reflectedRev(_ id: UUID) -> Int { canvases[id]?.reflectedRev ?? -1 }
    func unreflectedOpIDs(_ id: UUID) -> [Int] { canvases[id]?.unreflectedOpIDs ?? [] }

    // MARK: Transport — never moves `rev`

    private static func stopPlayback(_ t: inout ScriptCanvasTransport) {
        t.playing = false
        t.anchorSince = nil
    }

    /// Where the playhead is now: the wall-clock model while playing, the caret otherwise. A pure
    /// read (no mutation), so a view may call it from its body.
    func position(of id: UUID, at now: Date = Date()) -> Double {
        canvases[id]?.transport.position(at: now) ?? 0
    }

    /// Reaching the end of the longest file is a stop: playing off, position back on the caret.
    /// Called by every read, and by the window's timer.
    func settleTransport(_ id: UUID, at now: Date = Date()) {
        guard let c = canvases[id], c.transport.playing, let since = c.transport.anchorSince,
              c.transport.anchorPosition + now.timeIntervalSince(since) >= c.transport.end else { return }
        Self.stopPlayback(&canvases[id]!.transport)
        transportChanged?(id)
    }

    /// Starts at the caret and stops the PROJECT's transport. `invalid_state` without an original.
    func play(_ id: UUID) throws {
        let c = try openCanvas(id)
        guard c.transport.slots[.original] != nil else { throw Self.invalid("no original audio") }
        guard !c.transport.playing else { return }
        stopProjectTransport?()
        canvases[id]!.transport.playing = true
        canvases[id]!.transport.anchorPosition = c.transport.caret
        canvases[id]!.transport.anchorSince = Date()
        transportChanged?(id)
    }

    /// Stops; the position goes back to the caret.
    func stop(_ id: UUID) throws {
        _ = try canvas(id)
        guard canvases[id]!.transport.playing else { return }
        Self.stopPlayback(&canvases[id]!.transport)
        transportChanged?(id)
    }

    /// Sets the caret (clamped to [0, the end]) and, while playing, jumps there.
    func seek(_ id: UUID, to target: Double) throws {
        let c = try openCanvas(id)
        guard target.isFinite else { throw Self.bad("seek must be a finite number") }
        let t = Swift.min(c.transport.end, Swift.max(0, target))
        canvases[id]!.transport.caret = t
        if c.transport.playing {
            canvases[id]!.transport.anchorPosition = t
            canvases[id]!.transport.anchorSince = Date()
        }
        transportChanged?(id)
    }

    /// The three-state switch. `invalid_state` when the slot of that name is empty.
    func setListen(_ id: UUID, _ listen: CanvasListen) throws {
        let c = try openCanvas(id)
        guard c.transport.slots[CanvasSlot(rawValue: listen.rawValue)!] != nil else {
            throw Self.invalid("the \(listen.rawValue) slot is empty")
        }
        canvases[id]!.transport.listen = listen
        transportChanged?(id)
    }
}

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - dB gain control (a parallel branch's gain, the clip's volume)

/// A small dB readout: dragging ↑/↓ adjusts in 1 dB steps (without recompiling), double click = 0 dB.
/// (The chain's start/end gains it once served are gone: a gain is a stage now, with a card of its own.)
struct GainDbControl: View {
    let dB: Float
    var minDb: Float = -24
    var maxDb: Float = 12
    var unit: String = "dB"              // the unit shown next to the value
    var muted: Bool? = nil               // nil = no mute button (the clip's volume: its mute is the zone's own)
    var onToggleMute: (() -> Void)? = nil
    var onTouch: (() -> Void)? = nil     // called on TOUCH (click/drag/keyboard), before any change
    var onBegin: (() -> Void)? = nil     // called at the start of a drag (to push an undo point, say)
    let onChange: (Float) -> Void

    private var label: String { dB == 0 ? "0 \(unit)" : String(format: "%+.0f \(unit)", dB) }
    private var isMuted: Bool { muted == true }

    var body: some View {
        HStack(spacing: 3) {
            // Mute — a parallel branch's, to the left of the value.
            if let muted, let onToggleMute {
                Button(action: onToggleMute) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(muted ? Color.red : Color.secondary)
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(muted ? Color.red.opacity(0.18) : Color.secondary.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder((muted ? Color.red : Color.secondary).opacity(0.45)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("common.mute"))
            }
            gainReadout
        }
    }

    private var gainReadout: some View {
        // Reuses the value box (drag ↑/↓, click plus arrows, Delete = 0, direct typing).
        DragValueBox(value: Double(dB),
                     format: { _ in label },           // a signed label with its unit
                     range: Double(minDb)...Double(maxDb),
                     pointsPerStep: 6, snap: true, width: 46,
                     keyStep: 1,
                     help: L("help.drag.volume"),
                     onTouch: onTouch,
                     onBegin: onBegin,
                     onChange: { onChange(Float($0)) },
                     onReset: { onBegin?(); onChange(0) })   // the reset (double click/Delete) is undoable too
            .opacity(isMuted ? 0.5 : 1)
    }
}

// MARK: - Draggable value box ('gain' style: a value plus a unit, drag ↑/↓)

/// A small box showing a formatted value. Editing:
///  · dragging ↑/↓ adjusts (a step of 1 by default, ⌘ = fine adjustment);
///  · a click then the ↑/↓ arrows = a `keyStep` step, Delete = reset;
///  · a click then a digit = typing the value directly (Return commits, Esc cancels);
///  · a double click = reset.
/// Reused for speed / semitones / bpm / pan / gains.
struct DragValueBox: View {
    let value: Double
    let format: (Double) -> String
    var range: ClosedRange<Double>
    var pointsPerStep: CGFloat = 6
    /// true = rounds to the whole step (⌘ = fine); false = continuous (no snapping).
    var snap: Bool = true
    var width: CGFloat = 56
    /// Not applied to the keyboard's ↑/↓ arrows.
    var keyStep: Double = 1
    /// ↑/↓ with ⌘ / with ⇧ (nil = same as `keyStep`). The tempo boxes: ⌘ ±0.1, ⇧ ±10.
    var fineKeyStep: Double? = nil
    var coarseKeyStep: Double? = nil
    /// true = the box follows the length of what it shows (`width` becomes a minimum).
    var fitsContent: Bool = false
    /// Reads a direct keyboard entry (nil = refuse). By default: a plain number.
    var parse: (String) -> Double? = { Double($0.replacingOccurrences(of: ",", with: ".")) }
    var help: String = ""
    /// TOUCHING the control: a click, the start of a drag, or a keystroke — before any change,
    /// and even if there is none. Distinct from `onBegin`, which pushes an undo point and must
    /// therefore only run when a value really is about to change.
    var onTouch: (() -> Void)? = nil
    var onBegin: (() -> Void)? = nil
    var onChange: (Double) -> Void
    var onReset: (() -> Void)? = nil

    @State private var start: Double? = nil
    @State private var typing: String? = nil   // non-nil = direct keyboard entry under way
    @FocusState private var focused: Bool       // the container (display mode: drag / arrows / digit)
    @FocusState private var fieldFocused: Bool  // the TextField (typing mode)
    /// This instance's identity for `KeyboardClaim`, stable for the view's whole lifetime —
    /// distinct from `focused`/`fieldFocused`, which are SwiftUI's own and say nothing to the
    /// AppKit-level monitor.
    @State private var claimID = UUID()

    private var isFocused: Bool { focused || fieldFocused }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    private func bump(_ delta: Double) { onTouch?(); onBegin?(); onChange(clamp(value + delta)) }

    private func keyStep(for modifiers: EventModifiers) -> Double {
        if modifiers.contains(.command), let f = fineKeyStep { return f }
        if modifiers.contains(.shift), let c = coarseKeyStep { return c }
        return keyStep
    }

    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    /// The box's width: fixed, or measured on the text shown (typing or value) when it fits content.
    private var boxWidth: CGFloat {
        guard fitsContent else { return width }
        let text = typing ?? format(value)
        let w = (text as NSString).size(withAttributes: [.font: Self.valueFont]).width
        return max(width, ceil(w) + 12)
    }

    /// NSDeleteCharacter — what the ⌫ key actually TYPES on macOS.
    private static let deleteCharacter: Character = "\u{7F}"

    /// ⌫ / forward delete, read by CHARACTER and not by `KeyEquivalent` alone: the constant that
    /// carries the name does not carry the key. `.delete` is U+0008 — the old backspace character
    /// — while the ⌫ key types U+007F, so a `case .delete, .deleteForward` matched the FORWARD
    /// delete and nothing else, and ⌫ fell through unconsumed. Same family as the ⌥+letter trap:
    /// what a key MEANS and what it TYPES are two different questions.
    /// (Kept out of the body: the view builder could no longer type-check it in reasonable time.)
    private static func isResetKey(_ press: KeyPress) -> Bool {
        if press.key == .delete || press.key == .deleteForward { return true }
        return press.characters.first == deleteCharacter
    }

    /// Takes keyboard focus for THIS box. The crux of the 'digit → Search field' bug:
    /// a search/filter field ('Search…' / 'Filter…') can keep AppKit's FIRST RESPONDER while
    /// SwiftUI has given this box no more than visual focus. The global keyboard monitor
    /// (TimelineKeyHandler) bails as soon as the first responder is an `NSTextView` → the digit
    /// typed goes into that field instead of starting the entry here. So we take the first
    /// responder away from it (window → the SwiftUI hosting view) so that the keystroke reaches
    /// `onKeyPress`. A COMPULSORY passage for a plain click as for the start of a drag: so it is
    /// here, and only once, that 'this control has just been touched' is reported.
    private func grabKeyFocus() {
        onTouch?()
        focused = true
        if let win = NSApp.keyWindow, let fr = win.firstResponder,
           (fr is NSTextView || fr is NSTextField), fieldFocused == false {
            win.makeFirstResponder(nil)
        }
    }

    /// `refocus = false` when the caller is about to give the whole box's keyboard up right
    /// after (@see the `KeyboardClaim.revocation` handler) — deferring `focused = true` there
    /// would only have it undone a runloop hop later.
    private func commitTyping(refocus: Bool = true) {
        if let t = typing, let v = parse(t.trimmingCharacters(in: .whitespaces)) {
            onBegin?(); onChange(clamp(v))
        }
        typing = nil
        guard refocus else { return }
        // Giving focus back to the container MUST be deferred: done synchronously, it races with the
        // TextField being torn down (having just resigned) → the first responder shoots off to the
        // window/nowhere and the ↑/↓ arrows stop working until the view is rebuilt. One runloop hop
        // lets the TextField unmount first, then we refocus the container (drag/arrow mode).
        DispatchQueue.main.async { focused = true }
    }

    private func cancelTyping() {
        typing = nil
        DispatchQueue.main.async { focused = true }
    }

    var body: some View {
        Group {
            if typing != nil {
                TextField(noLabel, text: Binding(get: { typing ?? "" }, set: { typing = $0 }))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($fieldFocused)
                    .onSubmit { commitTyping() }
                    .onExitCommand { cancelTyping() }
            } else {
                Text(format(value))
            }
        }
        .font(.system(size: 10, weight: .medium)).monospacedDigit()
        .foregroundStyle(.primary)
        .frame(width: boxWidth, height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder((isFocused ? Color.accentColor : Color.secondary).opacity(isFocused ? 0.9 : 0.45),
                          lineWidth: isFocused ? 1.5 : 1))
        .contentShape(Rectangle())
        // Always focusable (even while typing): otherwise, the instant `typing` becomes non-nil, the
        // box would lose focus and — the TextField only being focused on the next runloop — the first
        // responder would shoot off to the 'Search…' field. By staying focusable, the container holds
        // the focus until the TextField takes it back.
        .focusable()
        .focused($focused)
        // Claim the keyboard for THIS box for as long as it shows any focus (container or
        // field), release it the instant neither does. The guard against the A/B race between
        // two boxes' focus changes lives in `KeyboardClaim.release` itself.
        .onChange(of: isFocused) { _, f in
            if f { KeyboardClaim.shared.claim(.valueField(claimID)) }
            else { KeyboardClaim.shared.release(.valueField(claimID)) }
        }
        // The timeline took the keyboard back (a click on the canvas, Escape…) with no `release`
        // of ours ever called. "Partir, c'est valider": a typed-but-uncommitted entry is
        // committed rather than dropped, then the box lets go of its own visual focus too.
        .onChange(of: KeyboardClaim.shared.revocation) { _, _ in
            if typing != nil { commitTyping(refocus: false) }
            focused = false
            fieldFocused = false
        }
        .onDisappear { KeyboardClaim.shared.release(.valueField(claimID)) }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if start == nil { start = value; onBegin?(); grabKeyFocus() }
                    let s = start ?? value
                    let fine = NSEvent.modifierFlags.contains(.command)
                    let raw = s - Double(v.translation.height) / Double(pointsPerStep)
                    let val = (snap && !fine) ? raw.rounded() : raw
                    onChange(clamp(val))
                }
                .onEnded { _ in start = nil }
        )
        .onTapGesture(count: 2) { onReset?() }
        .onTapGesture { grabKeyFocus() }
        .onKeyPress(phases: .down) { press in
            guard typing == nil else { return .ignored }   // typing under way → leave it to the TextField
            if Self.isResetKey(press) { onReset?(); return .handled }
            switch press.key {
            case .upArrow:   bump(keyStep(for: press.modifiers));  return .handled
            case .downArrow: bump(-keyStep(for: press.modifiers)); return .handled
            default:
                guard let ch = press.characters.first,
                      ch.isNumber || ch == "-" || ch == "." || ch == "," else {
                    return .ignored
                }
                typing = String(ch)
                DispatchQueue.main.async {
                    fieldFocused = true
                    // AppKit selects all of the field editor's text when it becomes
                    // first responder programmatically. We put the cursor back at the end of
                    // text so that the next digit is added instead of replacing.
                    DispatchQueue.main.async {
                        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                            editor.selectedRange = NSRange(location: editor.string.count, length: 0)
                        }
                    }
                }
                return .handled
            }
        }
        .help(help)
    }
}

// MARK: - The box of the zones that straddle the object frame

/// The box of a head / mixer zone: OPAQUE (docs/plan_synoptic_rework.md §B.5). The object frame runs from the
/// head zone's midline to the mixer's midline, so its edge passes BEHIND these zones and they straddle it:
/// a translucent tint would show the frame's line through them. The tint is the one the zones always had,
/// laid over the same opaque ground as a plugin card's.
struct SynopticZoneBox: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        shape.fill(Color(nsColor: .controlBackgroundColor))
            .overlay(shape.fill(Color.secondary.opacity(0.06)))
            .overlay(shape.strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - The 'audio file' zone (an audio clip): loop / reverse, and the options speed / semitones / bpm / channels
//
// FOLDED (the default, @see SynopticUIState.clipOptionsExpanded) the zone is ONE row: the title, a pill for
// each hidden setting that is not neutral, then loop, reverse and the chevron. Loop and reverse stay one
// click away. UNFOLDED, the options come under that same row. The chevron AND a double click anywhere on
// the zone (a value box keeps its own double click, "reset") fold and unfold it. The memory is global to
// the session, not per object.

struct AudioFileZoneView: View {
    let rect: CGRect
    let file: SynopticAudioFile
    let actions: SynopticActions
    /// Is the zone laid folded? nil = read it off the room the layout gave it (one row), which is the one
    /// source of truth: the content can never overflow the rect it was handed.
    var folded: Bool? = nil
    @State private var bpmBaseText: String = ""
    @FocusState private var baseFocused: Bool
    /// Same fallback as `TransportView`'s tempo field, and for the same reason: ⌘↑/⌘↓ risk being
    /// eaten by the text view's own "move to beginning/end of document" binding before
    /// `onKeyPress` ever sees them.
    @State private var baseCommandArrowMonitor: Any?

    private static let baseBpmFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let baseBpmCharWidth: CGFloat =
        ("0" as NSString).size(withAttributes: [.font: baseBpmFont]).width

    private func baseBpmFieldWidth(for text: String) -> CGFloat {
        let chars = max(2, text.count)
        return CGFloat(chars) * Self.baseBpmCharWidth + 6
    }

    private func nudgeBaseBPM(by delta: Double) {
        let current = file.baseBPM ?? 0
        let next = TempoText.rounded(max(0.0001, current + delta))
        actions.onSetBaseBPM?(next)
    }

    private func installBaseCommandArrowMonitorIfNeeded() {
        guard baseCommandArrowMonitor == nil else { return }
        baseCommandArrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard baseFocused, event.modifierFlags.contains(.command),
                  event.keyCode == 125 || event.keyCode == 126 else { return event }
            nudgeBaseBPM(by: event.keyCode == 126 ? 0.1 : -0.1)
            return nil
        }
    }

    private func removeBaseCommandArrowMonitor() {
        if let m = baseCommandArrowMonitor { NSEvent.removeMonitor(m); baseCommandArrowMonitor = nil }
    }

    private var semis: Double { 12 * log2(max(1e-6, file.speedRatio)) }
    private var targetBPM: Double? { file.baseBPM.map { $0 * file.speedRatio } }

    /// The zone is folded: laid on one row (or told so by the caller).
    private var isFolded: Bool { folded ?? (rect.height < SynopticLayout.audioZoneH - 0.5) }

    private func stLabel(_ s: Double) -> String {
        let r = s.rounded()
        if abs(s - r) < 0.05 { return r == 0 ? "0 st" : String(format: "%+.0f st", r) }
        return String(format: "%+.1f st", s)
    }

    /// Folds / unfolds the options. The closure is the caller's (`SynopticActions.onToggleClipOptions`); with
    /// none, the zone flips the session memory itself — it is app-wide and not an edit, so there is nothing
    /// else for a caller to add. Folding first lets go of what was being typed (a hidden field would drop it).
    private func toggleFold() {
        if !isFolded {
            if baseFocused { commitBase() }
            KeyboardClaim.shared.revoke()      // a value box mid-entry commits ("leaving is validating")
        }
        if let toggle = actions.onToggleClipOptions { toggle() }
        else { SynopticUIState.shared.toggleClipOptions() }
    }

    var body: some View {
        zone
            .frame(width: rect.width, height: rect.height)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            // Anywhere on the zone but a button or a value box (their own gestures win over this one).
            .onTapGesture(count: 2) { toggleFold() }
            .position(x: rect.midX, y: rect.midY)
            .onAppear { syncBaseText() }
            .onChange(of: file.baseBPM) { _, _ in syncBaseText() }
    }

    private var zone: some View {
        ZStack(alignment: .topLeading) {
            SynopticZoneBox()

            VStack(alignment: .leading, spacing: 7) {
                titleRow

                if !isFolded {
                    // LR / L / R / C — stereo files only; the zone is taller by one row then (@see
                    // SynopticLayout.audioZoneStereoExtraH).
                    if let current = file.channelMode {
                        HStack(spacing: 4) {
                            Text(L("inspector.channelMode.title"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).fixedSize()
                            ForEach(ChannelMode.allCases, id: \.self) { mode in
                                Button { actions.onSetChannelMode?(mode) } label: {
                                    Text(channelModeLabel(mode))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(current == mode ? Color.white : Color.secondary)
                                        .padding(.horizontal, 6).frame(height: 16)
                                        .background(RoundedRectangle(cornerRadius: 4)
                                            .fill(current == mode ? Color.accentColor : Color.secondary.opacity(0.18)))
                                        .overlay(RoundedRectangle(cornerRadius: 4)
                                            .strokeBorder(Color.secondary.opacity(0.35)))
                                }
                                .buttonStyle(.plain)
                                .help(channelModeHelp(mode))
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    optionsRow
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, isFolded ? (SynopticLayout.audioZoneFoldedH - 16) / 2 : 8)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        }
    }

    // MARK: Row 1 — always visible: title, [pills], loop, reverse, chevron

    private var titleRow: some View {
        HStack(spacing: 4) {
            Text(L("synoptic.audioFile"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if isFolded {
                // A hidden setting that is not neutral says so (§B.7). Passive: a double click on one opens
                // the zone like anywhere else.
                ForEach(Array(file.hiddenNonNeutralSettings.enumerated()), id: \.offset) { _, setting in
                    hiddenPill(setting)
                }
            }
            Spacer(minLength: 0)
            loopButton
            reverseButton
            chevronButton
        }
        .frame(height: 16)
    }

    private var loopButton: some View {
        Button { actions.onToggleLoop?() } label: {
            Text(L("synoptic.loop.label"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(file.isLooping ? Color.white : Color.secondary.opacity((file.isReversed || file.ara != nil) ? 0.4 : 1))
                .padding(.horizontal, 6).frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(file.isLooping ? Color.accentColor : Color.secondary.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(file.isReversed || file.ara != nil)
        // Looping is not handled in reverse yet: the source anchor is recomputed from the
        // length, which becomes unbounded precisely when looping (@see [[loop-item-plan]]).
        .help(file.ara != nil ? L("synoptic.ara.timeLocked")
              : file.isReversed ? L("synoptic.loop.unavailableReversed")
              : file.isLooping ? L("synoptic.loop.on")
              : L("synoptic.loop.off"))
    }

    private var reverseButton: some View {
        Button { actions.onToggleReverse?() } label: {
            Text(L("synoptic.reverse.label"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(file.isReversed ? Color.white : Color.secondary)
                .padding(.horizontal, 6).frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(file.isReversed ? Color.accentColor : Color.secondary.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(file.ara != nil && !file.isReversed)
        .opacity(file.ara != nil && !file.isReversed ? 0.4 : 1)
        .help(file.ara != nil && !file.isReversed ? L("synoptic.ara.timeLocked")
              : file.isReversed ? L("synoptic.reverse.on") : L("synoptic.reverse.off"))
    }

    /// The fold's chevron: points right when the options are hidden, down when shown.
    private var chevronButton: some View {
        Button { toggleFold() } label: {
            Image(systemName: isFolded ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFolded ? L("synoptic.audioFile.unfold") : L("synoptic.audioFile.fold"))
    }

    // MARK: A pill for a hidden setting that is not neutral

    private func hiddenPill(_ setting: SynopticHiddenSetting) -> some View {
        let text: String
        let help: String
        switch setting {
        case .pitch(let semitones, let ratio):
            text = SynopticZonePills.pitchText(semitones: semitones, ratio: ratio)
            help = L("synoptic.audioFile.pill.speed", SynopticZonePills.ratioText(ratio))
        case .tempo(let bpm):
            text = SynopticZonePills.tempoText(targetBPM: bpm)
            help = L("synoptic.audioFile.pill.tempo", TempoText.display(TempoText.rounded(bpm)))
        case .channel(let mode):
            text = channelModeLabel(mode)
            help = channelModeHelp(mode)
        }
        return Text(verbatim: text)
            .font(.system(size: 9, weight: .medium)).monospacedDigit()
            .foregroundStyle(Color.accentColor)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.45)))
            .help(help)
    }

    // MARK: Row 2 (unfolded) — 1× / st / bpm on the same line (saving height)

    private var optionsRow: some View {
        HStack(spacing: 6) {
            DragValueBox(value: semis,
                         format: { String(format: "%.2f×", pow(2.0, $0 / 12.0)) },
                         range: -48...48, pointsPerStep: 6, snap: false, width: 52,
                         keyStep: 1,
                         parse: { Double($0.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "×", with: "").replacingOccurrences(of: "x", with: "")).map { 12 * log2(max(1e-6, $0)) } },
                         help: L("help.drag.speed"),
                         onBegin: { actions.onBeginSpeedEdit?() },
                         onChange: { actions.onSetSpeed?(pow(2.0, $0 / 12.0)) },
                         onReset: { actions.onSetSpeed?(1.0) })
            DragValueBox(value: semis,
                         format: stLabel,
                         range: -48...48, pointsPerStep: 6, width: 48,
                         keyStep: 1,
                         help: L("help.drag.semitones"),
                         onBegin: { actions.onBeginSpeedEdit?() },
                         onChange: { actions.onSetSpeed?(pow(2.0, $0 / 12.0)) },
                         onReset: { actions.onSetSpeed?(1.0) })

            Spacer(minLength: 0)

            TextField(text: $bpmBaseText) { Text(verbatim: "—") }
                .frame(width: baseBpmFieldWidth(for: bpmBaseText)).multilineTextAlignment(.center)
                .font(.system(size: 10, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(.horizontal, 3).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.45)))
                .focused($baseFocused)
                .onSubmit { commitBase() }
                .onChange(of: baseFocused) { _, focused in
                    if focused { installBaseCommandArrowMonitorIfNeeded() }
                    else { removeBaseCommandArrowMonitor() }
                }
                .onDisappear { removeBaseCommandArrowMonitor() }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    let step: Double = press.modifiers.contains(.command) ? 0.1
                        : press.modifiers.contains(.shift) ? 10
                        : 1
                    nudgeBaseBPM(by: press.key == .upArrow ? step : -step)
                    return .handled
                }
                .help(L("synoptic.wavBPM"))

            Image(systemName: "arrow.right")
                .font(.system(size: 8)).foregroundStyle(.tertiary)

            if let base = file.baseBPM, base > 0 {
                // Same rules as the wav BPM field and the transport tempo: up to 4 decimals shown
                // only when needed, ',' or '.', ⌘↑/↓ ±0.1, ⇧ ±10, width follows the text.
                DragValueBox(value: targetBPM ?? base,
                             format: { TempoText.display(TempoText.rounded($0)) },
                             range: 20...400, pointsPerStep: 2, width: 38,
                             keyStep: 1, fineKeyStep: 0.1, coarseKeyStep: 10,
                             fitsContent: true,
                             parse: { TempoText.parse($0) },
                             help: L("help.drag.bpm"),
                             onBegin: { actions.onBeginSpeedEdit?() },
                             onChange: { actions.onSetSpeed?(TempoText.rounded($0) / base) },
                             // ⌫ / double-click: back to the wav's own BPM (speed 1).
                             onReset: { actions.onBeginSpeedEdit?(); actions.onSetSpeed?(1.0) })
            } else {
                Text(verbatim: "—")
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
            }

            // Never squeezed: the two BPM fields widen with their text, and without this
            // the unit was what gave way — shrinking, then gone.
            Text(verbatim: "bpm").font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize()
                .layoutPriority(1)
        }
        // An ARA source needs speed 1: the speed / semitone / bpm boxes only show it then.
        .allowsHitTesting(file.ara == nil)
        .opacity(file.ara == nil ? 1 : 0.45)
    }

    // One literal key per case, on purpose: `orphans` reads the code for key-shaped strings.
    private func channelModeLabel(_ mode: ChannelMode) -> String {
        switch mode {
        case .lr: return L("inspector.channelMode.lr")
        case .l:  return L("inspector.channelMode.l")
        case .r:  return L("inspector.channelMode.r")
        case .c:  return L("inspector.channelMode.c")
        }
    }

    private func channelModeHelp(_ mode: ChannelMode) -> String {
        switch mode {
        case .lr: return L("inspector.channelMode.lr.help")
        case .l:  return L("inspector.channelMode.l.help")
        case .r:  return L("inspector.channelMode.r.help")
        case .c:  return L("inspector.channelMode.c.help")
        }
    }

    private func syncBaseText() {
        guard !baseFocused else { return }
        if let base = file.baseBPM {
            bpmBaseText = TempoText.display(base)
        } else {
            bpmBaseText = ""
        }
    }

    private func commitBase() {
        let t = bpmBaseText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { actions.onSetBaseBPM?(nil) }
        else if let v = TempoText.parse(t), v > 0 { actions.onSetBaseBPM?(v) }
        syncBaseText()
    }
}

// MARK: - The 'clip' zone (the output mix): volume / pan / mute
//
// Reuses GainDbControl (a gain box plus a mute icon) for the volume, and adapts it through
// DragValueBox for the pan (the C / L xx% / R xx% format).

struct ClipMixZoneView: View {
    let rect: CGRect
    let mix: SynopticMix
    let actions: SynopticActions

    private func panLabel(_ p: Float) -> String {
        if abs(p) < 0.01 { return "C" }
        return p < 0 ? "L \(Int((-p * 100).rounded()))%" : "R \(Int((p * 100).rounded()))%"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // OPAQUE: the mixer straddles the object frame's lower edge (@see SynopticZoneBox).
            SynopticZoneBox()
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Title plus pan / volume / mute on ONE line (saving height).
            HStack(spacing: 6) {
                // Never wrapped (like the 'bpm' unit): the zone widens instead (@see clipZoneW).
                Text(mix.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                // A 'linked consolidated object' marker (the attributes below carry a link icon).
                if mix.attrLinks != nil {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(LinkColor.consolidate)
                        .help(L("synoptic.consolidate.linked"))
                }
                Spacer(minLength: 0)
                // Each attribute: the value, then (tight to the right) its link icon.
                HStack(spacing: 3) {
                    // keyStep = the DETENT itself (@see EditViewModel+Pan): the arrows walk the
                    // tenths, they do not halve them. The drag stays continuous here and is brought
                    // onto the detent on the way in, by `setPanFromHand`.
                    DragValueBox(value: Double(mix.pan),
                                 format: { panLabel(Float($0)) },
                                 range: -1...1, pointsPerStep: 80, snap: false, width: 52,
                                 keyStep: 0.1,
                                 parse: { Double($0.replacingOccurrences(of: ",", with: ".")).map { $0 / 100 } },
                                 help: L("help.drag.pan"),
                                 onTouch: { actions.onTouchParam?(.pan) },
                                 onBegin: { actions.onBeginMixEdit?() },
                                 onChange: { actions.onSetPan?(Float($0)) },
                                 onReset: { actions.onSetPan?(0) })
                        .automationLocked(mix.panAutomated)
                    if let links = mix.attrLinks { attrLinkBadge(.pan, synced: links.panSynced) }
                }
                HStack(spacing: 3) {
                    GainDbControl(dB: mix.volumeDb, minDb: -96, maxDb: 40,
                                  onTouch: { actions.onTouchParam?(.volume) },
                                  onBegin: { actions.onBeginMixEdit?() }) { newDB in
                        actions.onSetVolume?(newDB)
                    }
                    .automationLocked(mix.volumeAutomated)
                    if let links = mix.attrLinks { attrLinkBadge(.volume, synced: links.volumeSynced) }
                }
                HStack(spacing: 3) {
                    muteButton
                    soloButton
                    if let links = mix.attrLinks { attrLinkBadge(.mute, synced: links.muteSynced) }
                }
            }
            .padding(.horizontal, 10)
            .frame(width: rect.width, height: rect.height, alignment: .leading)
            .position(x: rect.midX, y: rect.midY)
        }
    }

    /// An attribute's link icon (a consolidated object): green = synced between instances,
    /// red = independent. Double click to flip the state.
    private func attrLinkBadge(_ attr: SynopticMixAttr, synced: Bool) -> some View {
        Image(systemName: "arrow.down.left.arrow.up.right.square.fill")
            .font(.system(size: 17))
            .foregroundStyle(synced ? Color.green : Color.red)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { actions.onToggleAttrSync?(attr) }
            .help(synced
                  ? L("synoptic.consolidate.attrSynced")
                  : L("synoptic.consolidate.attrIndependent"))
    }

    private var muteButton: some View {
        Button { actions.onToggleMute?() } label: {
            Image(systemName: mix.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(mix.isMuted ? Color.red : Color.secondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(mix.isMuted ? Color.red.opacity(0.18) : Color.secondary.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder((mix.isMuted ? Color.red : Color.secondary).opacity(0.45)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("common.mute"))
    }

    /// The object's solo: ONE button for both layers. Tinted = temporary (it will clear itself),
    /// solid = held (it stays). A click always writes into the held layer — it is the only one a
    /// click can own (@see EditViewModel.toggleSoloHold).
    private var soloButton: some View {
        let hold = mix.solo == .hold
        let on   = mix.solo != .off
        return Button { actions.onToggleSolo?() } label: {
            Image(systemName: "headphones")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hold ? Color.black : (on ? Color.yellow : Color.secondary))
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(hold ? Color.yellow
                               : (on ? Color.yellow.opacity(0.18) : Color.secondary.opacity(0.18))))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder((on ? Color.yellow : Color.secondary).opacity(0.45)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hold ? L("synoptic.solo.held")
                   : (on ? L("synoptic.solo.temporary") : L("synoptic.solo")))
    }
}

/// A bus's chain head (aux / group): 'source', the infinite option, and — for an aux —
/// the list of the sends it receives (the incoming signal comes from there).
struct BusHeadZoneView: View {
    let rect: CGRect
    let infinite: SynopticInfinite?
    let loop: SynopticLoop?
    let received: [SynopticSend]
    let actions: SynopticActions

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(L("synoptic.source"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let lp = loop { loopToggle(lp) }
                    if let inf = infinite { infiniteToggle(inf) }
                }
                .frame(height: SynopticLayout.pillH)
                ForEach(received) { s in
                    SynopticSendRow(send: s, outgoing: false, actions: actions)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .position(x: rect.midX, y: rect.midY)
        }
    }

    private func loopToggle(_ lp: SynopticLoop) -> some View {
        Button { actions.onToggleLoop?() } label: {
            HStack(spacing: 4) {
                Image(systemName: "repeat")
                    .font(.system(size: 10, weight: .bold))
                Text(L("synoptic.loop.label"))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(lp.isOn ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 7).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill((lp.isOn ? Color.accentColor : Color.secondary).opacity(lp.isOn ? 0.18 : 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder((lp.isOn ? Color.accentColor : Color.secondary).opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("synoptic.loop"))
    }

    private func infiniteToggle(_ inf: SynopticInfinite) -> some View {
        Button { actions.onToggleInfinite?() } label: {
            HStack(spacing: 4) {
                Image(systemName: "infinity")
                    .font(.system(size: 10, weight: .bold))
                Text(L("synoptic.infinite"))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(inf.isOn ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 7).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill((inf.isOn ? Color.accentColor : Color.secondary).opacity(inf.isOn ? 0.18 : 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder((inf.isOn ? Color.accentColor : Color.secondary).opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("synoptic.infinite.help", inf.kindLabel))
    }
}

// MARK: - The 'stems' zone (output): choosing the destination stem
//
// It only shows and selects (creating and renaming stems happen in the toolbar). The current
// badge is ringed in white; a click reassigns.

struct StemsZoneView: View {
    let rect: CGRect
    let stems: [SynopticStem]
    let onAssign: (UUID) -> Void

    private var current: SynopticStem? { stems.first { $0.isCurrent } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // The title plus the destination stem's drop-down menu, on one line.
            HStack(spacing: 8) {
                Text(L("synoptic.zone.stems"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu {
                    ForEach(Array(stems.enumerated()), id: \.element.id) { idx, stem in
                        // The number prefix = the keyboard shortcut (1 = Main, 2 = the 2nd stem…).
                        let prefix = idx < 9 ? "\(idx + 1)  " : ""
                        // A `String` and not a literal: see `ObjectInspectorView`, same trap.
                        let title = "\(prefix)\(stem.name)"
                        Button { onAssign(stem.id) } label: {
                            if stem.isCurrent { Label(title, systemImage: "checkmark") }
                            else { Text(verbatim: title) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill((current?.color ?? .secondary).opacity(0.85))
                            .frame(width: 11, height: 11)
                        Text(current?.name ?? "—")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.45)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(width: rect.width, height: rect.height, alignment: .leading)
            .position(x: rect.midX, y: rect.midY)
        }
    }
}

// MARK: - The 'output' zone of a group's child: routed to the group (read only)
//
// A group's child has no stem assignment of its own: its output feeds the group's submix,
// and it is the (root) group that belongs to a stem. The colour badge is a reminder of the
// effective stem at the end of the chain.

struct GroupRoutingZoneView: View {
    let rect: CGRect
    let routing: SynopticGroupRouting

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            HStack(spacing: 8) {
                Text(L("synoptic.zone.output"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Circle()
                        .fill(routing.stemColor.opacity(0.85))
                        .frame(width: 11, height: 11)
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(routing.groupName)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 7).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.10)))
                .fixedSize()
                .help(L("synoptic.routedToGroup", routing.groupName))
            }
            .padding(.horizontal, 12)
            .frame(width: rect.width, height: rect.height, alignment: .leading)
            .position(x: rect.midX, y: rect.midY)
        }
    }
}

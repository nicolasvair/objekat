import SwiftUI

// MARK: - An input's rectangle (docs/plan_groupes_midi.md, the inputs panel)
//
// Every input of the Inputs tab, audio or MIDI, is a rounded rectangle like a stem's strip in the toolbar (`StripStyle`
// carries the look both share), tinted with the Main's colour: a leading column (its number, the keys glyph, or the computer
// keyboard's button and octave), its name with the badges of what its chain does (`ObjectFeatureBadges`, the sound list's own
// glyphs) and under the name the linear level meter, which stops there; the speaker that hears it and its listening level
// sit at the right, centred on the two lines. A click SELECTS it and opens its popup — the synoptic of its chain, instrument then effects for a
// MIDI input, the effects for a card's (`InputStripPopup`); ⌘ and ⇧ only select (@see InputStripClick).
//
// This file is the rectangle and its popup, and nothing more: the clicks, the drag, the drops and the poll are the
// callers' (`InputsPanelView` for the card's inputs, `MidiInputsSection` for the MIDI ones), which hand it what to show.

/// What a rectangle shows where the card's rows had their number.
enum InputStripGlyph {
    case number(String)
    case keys
}

struct InputStrip<Leading: View, Gain: View, Meter: View>: View {
    /// The Main's colour (`EditViewModel.mainStemColor`): the inputs are drawn like the bus they are heard on.
    let tint: Color
    let name: String
    /// The name is a field (⌘R on a rectangle whose popup is closed).
    var isRenaming: Bool = false
    var onRename: (String?) -> Void = { _ in }
    var badges: [FeatureBadge] = []
    var isSelected: Bool = false
    var isOpen: Bool = false
    /// A drag that will drop on it is over it (@see the drops on the rectangles).
    var isDropTarget: Bool = false
    var heard: Bool = false
    /// A MIDI input without an instrument has nothing to hear: its speaker is inert.
    var canListen: Bool = true
    var listenHelp: String = ""
    var nameHelp: String = ""
    var onListen: () -> Void = {}
    /// The leading column, `InputRowStyle.leadingWidth` wide: the number, the keys glyph, or the computer keyboard's
    /// button with its octave selector.
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let gain: () -> Gain
    @ViewBuilder let meter: () -> Meter

    var body: some View {
        // The meter ends under the NAME: the speaker and the gain sit at the right, centred on the two lines.
        HStack(alignment: .center, spacing: InputRowStyle.controlSpacing) {
            leading()
                .frame(width: InputRowStyle.leadingWidth, alignment: .center)
            VStack(alignment: .leading, spacing: InputRowStyle.lineSpacing) {
                // The badges stay whole, the name is what gives way.
                NameWithFeatureBadges(badges: badges, size: 9, color: Color.secondary, keepsBadges: true) { nameView }
                meter()
                    .frame(height: 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            listenButton
            gain()
        }
        .stripChrome(tint: tint, isOpen: isOpen, isDropTarget: isDropTarget, isSelected: isSelected)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var nameView: some View {
        if isRenaming {
            // Leaving commits what was typed, Esc cancels (@see MarkerRenameField).
            MarkerRenameField(initial: name, font: InputRowStyle.nameFont, commitsOnFocusLoss: true, onCommit: onRename)
        } else {
            Text(verbatim: name)
                .font(InputRowStyle.nameFont)
                .lineLimit(1)
                .help(nameHelp)
        }
    }

    private var listenButton: some View {
        Button(action: onListen) {
            Image(systemName: heard ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.system(size: 15))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(heard ? Color.accentColor : Color.secondary)
        .opacity(canListen ? 1 : 0.4)
        .disabled(!canListen)
        .help(listenHelp)
    }
}

/// What the leading column shows for an input that has no controls of its own: its number (a card input) or the keys
/// glyph (a MIDI input). Shared by the live rectangle and the dormant one.
struct InputStripGlyphView: View {
    let glyph: InputStripGlyph
    var style: HierarchicalShapeStyle = .secondary

    var body: some View {
        switch glyph {
        case .number(let key):
            Text(verbatim: key)
                .font(InputRowStyle.numberFont)
                .lineLimit(1)
                .foregroundStyle(style)
        case .keys:
            Image(systemName: ObjectKindIcon.recordMidiInput)
                .font(.system(size: 14))
                .foregroundStyle(style)
        }
    }
}

/// The listening level of an input, in dB, on its rectangle: the synoptic's gain box (drag, ⇧ fine, arrows, typing,
/// double-click = 0 dB). Hearing only — it does not touch what is recorded. Greyed and inert while the input is not heard.
/// Shared by the card's inputs and the MIDI ones.
struct InputMonitorGainBox: View {
    let value: Double
    let heard: Bool
    let onChange: (Double) -> Void

    /// The most a DRAG may raise the level above where it started (a typed value is only held to the box's range).
    private static let riseLimit: Double = 6
    private static let range = Double(GainStageValues.gainRange.lowerBound)...Double(GainStageValues.gainRange.upperBound)

    var body: some View {
        DragValueBox(value: value,
                     format: { $0 == 0 ? "0 dB" : String(format: "%+.0f dB", $0) },
                     range: Self.range,
                     pointsPerStep: 6, snap: true, width: 44,
                     keyStep: 1, fineKeyStep: FineAdjust.dbFineStep, coarseKeyStep: FineAdjust.dbBigStep,
                     dragRiseLimit: Self.riseLimit,
                     help: L("inputs.monitorGain.help"),
                     onChange: onChange,
                     onReset: { onChange(0) })
            .opacity(heard ? 1 : 0.4)
            .disabled(!heard)
    }
}

/// The rectangle of a chain whose input is not there now (a smaller card, a pair taken apart, a MIDI device unplugged):
/// kept, greyed, with what it carries — nothing to hear, to drag or to drop on.
struct DormantInputStrip: View {
    let glyph: InputStripGlyph
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: InputRowStyle.controlSpacing) {
            InputStripGlyphView(glyph: glyph, style: .tertiary)
                .frame(width: InputRowStyle.leadingWidth, alignment: .center)
            Text(verbatim: name)
                .font(InputRowStyle.nameFont)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: detail)
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .stripChrome(tint: StripStyle.inputTint, isOpen: false)
        .opacity(0.45)
        .help(L("inputs.dormant.help"))
    }
}

/// The popup of an open rectangle: the input's name (a field after ⌘R, for a card input), what the chain is for, and the
/// SAME signal view as a stem's on the chain's host id (`SynopticBoundView`). A MIDI input shows its instrument slot and then
/// its effects, as a MIDI object does; a card input its effects. The chain is held mounted on the engine for as long as the
/// popup is open (`EditViewModel.openInputStrip`).
struct InputStripPopup: View {
    @Bindable var viewModel: EditViewModel
    let source: RecordSource

    private let popoverWidth: CGFloat = 300

    private var hostID: UUID? {
        switch source {
        case .audio(let ref):
            return viewModel.audioInputHostID(ref)
        case .midi(let ref):
            return MidiInputResolver.resolve(ref, in: viewModel.midiInputs).flatMap { viewModel.midiInputHostID($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                header
                Spacer(minLength: 12)
                Text(L("inputs.fx.note"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(viewModel.mainStemColor.opacity(0.20))
            Divider()
            if let hostID {
                SynopticBoundView(viewModel: viewModel, objectID: hostID, scrolls: true)
                    .frame(width: popoverWidth, height: 360)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(width: popoverWidth)
    }

    @ViewBuilder
    private var header: some View {
        switch source {
        case .audio(let ref):
            if viewModel.renamingInput == ref {
                // ⌘R while the popup is open (@see RenameShortcutRoute): leaving the field commits what was typed, Esc cancels.
                MarkerRenameField(initial: viewModel.inputName(ref),
                                  font: .system(.caption, weight: .semibold),
                                  commitsOnFocusLoss: true) { value in
                    if let value { viewModel.renameInput(ref, to: value) }
                    if viewModel.renamingInput == ref { viewModel.renamingInput = nil }
                }
            } else {
                Text(verbatim: viewModel.inputName(ref))
                    .font(.system(.caption, weight: .semibold))
                    .help(L("inputs.rename.help"))
            }
        case .midi(let ref):
            // The device's own name is its name (no rename).
            Text(verbatim: MidiInputResolver.resolve(ref, in: viewModel.midiInputs)?.displayName ?? ref.name)
                .font(.system(.caption, weight: .semibold))
        }
    }
}

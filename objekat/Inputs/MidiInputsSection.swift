import SwiftUI
import Combine

/// The « MIDI inputs » section of the Inputs tab (rec3-midi): ABOVE the card's inputs, in the same rows
/// (@see InputRowStyle) — the keys glyph where the card's rows have their number, the name, and under it a
/// bar that lights with the velocity of the notes played (the plugin cards' bar, 0...127 linear). A MIDI
/// input needs no sound card: the section is there whether or not the audio inputs are open. "All MIDI Ins"
/// comes first.
///
/// A row is dragged onto the timeline to make a MIDI recording zone, or onto a group to give it this input
/// (the same drop as a card input, @see InputDragSession). Dragging a selection that holds both kinds takes
/// them all: one lane per input, the MIDI ones first. The selection is the model's (`selectedMidiInputs`, the
/// device ids): a click selects the row alone and lets go of the card's selection, ⌘ adds or removes, ⇧
/// extends a range. No rename in v1 (the device's own name is the name).
///
/// A MIDI input can carry ONE instrument (docs/plan_groupes_midi.md, E10): its button, on the row, names it (« Instrument »
/// while there is none) and opens the picker or the instrument's editor; the speaker hears the input through it (greyed
/// while there is no instrument) — and it is the ONLY way to hear it live: arming a recording zone on the input is not
/// listening (the zone's capture track plays nothing), the zone's own instrument plays the takes the zone holds. A chain
/// whose device is absent stays as a greyed row, instrument kept.
///
/// The « Computer Keyboard » row (second, under « All MIDI Ins ») is a row like the others, plus its own line of controls
/// (`ComputerKeyboardRowControls`: the mode and the octave) — the mode is what feeds it, @see EditViewModel+ComputerKeyboard.
struct MidiInputsSection: View {
    @Bindable var viewModel: EditViewModel
    /// The list this section lives in takes the keyboard when a row is clicked.
    var focusList: () -> Void = {}

    /// Smoothed bar position 0...1 of each device.
    @State private var levels: [String: Float] = [:]
    /// The devices heard through their instrument (the engine owns it; read on the poll).
    @State private var heard: Set<String> = []
    @State private var poll = Timer.publish(every: 0.07, on: .main, in: .common).autoconnect()

    private var rows: [MidiInputInfo] { viewModel.midiInputs }
    private var selection: Set<String> {
        get { viewModel.selectedMidiInputs }
        nonmutating set { viewModel.selectedMidiInputs = newValue }
    }

    /// The chains whose device is not there: (chain key, chain), in key order.
    private var dormant: [(key: String, chain: MidiInputChain)] {
        viewModel.inputChains.midi
            .filter { !$0.value.isEmpty && viewModel.resolvedMidiInput($0.value.input) == nil }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, chain: $0.value) }
    }

    var body: some View {
        Group {
            if !rows.isEmpty || !dormant.isEmpty {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Text(L("inputs.section.midi"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, InputRowStyle.horizontalPadding + 2)
                            .padding(.top, 8).padding(.bottom, 4)
                        Divider()
                    }
                    ForEach(rows, id: \.id) { row($0) }
                    ForEach(dormant, id: \.key) { dormantRow(key: $0.key, chain: $0.chain) }
                }
            }
        }
        .onReceive(poll) { _ in tick() }
        .onAppear { viewModel.refreshMidiInputs() }
    }

    private func row(_ d: MidiInputInfo) -> some View {
        let isSelected = selection.contains(d.id)
        let hasInstrument = viewModel.midiChainKey(for: d).flatMap { viewModel.inputChains.midi[$0]?.instrument } != nil
        return VStack(alignment: .leading, spacing: InputRowStyle.lineSpacing) {
            HStack(spacing: InputRowStyle.controlSpacing) {
                Image(systemName: ObjectKindIcon.recordMidiInput)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: InputRowStyle.numberWidth, alignment: .trailing)
                Text(verbatim: d.displayName)
                    .font(InputRowStyle.nameFont)
                    .lineLimit(1)
                Spacer(minLength: 4)
                MidiInstrumentButton(viewModel: viewModel, device: d)
                monitorButton(d, hasInstrument: hasInstrument)
            }
            if d.isComputerKeyboard {
                ComputerKeyboardRowControls(viewModel: viewModel)
                    .padding(.leading, InputRowStyle.meterLeading)
            }
            VULevelBar(level: Double(levels[d.id] ?? 0), height: 3)
                .frame(height: 5)
                .padding(.leading, InputRowStyle.meterLeading)
                .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                    length * InputRowStyle.meterWidthFraction
                }
        }
        .inputRowChrome(isSelected: isSelected)
        .contentShape(Rectangle())
        .onDrag { InputDragSession.shared.begin(sources: viewModel.draggedSources(startingFrom: .midi(d.ref))) }
        .onTapGesture {
            focusList()
            viewModel.renamingInput = nil
            let flags = NSEvent.modifierFlags
            let next = ListClickSelection.apply(current: selection, clicked: d.id, ordered: rows.map(\.id),
                                                shift: flags.contains(.shift), command: flags.contains(.command))
            // A plain click is the only selection; ⌘ and ⇧ keep the card's rows a drag may add.
            if !flags.contains(.command) && !flags.contains(.shift) { viewModel.selectedRecordInputs = [] }
            selection = next
        }
    }

    /// The speaker: hears the input through its instrument. Greyed and inert while there is none.
    private func monitorButton(_ d: MidiInputInfo, hasInstrument: Bool) -> some View {
        let on = heard.contains(d.id)
        return Button {
            _ = viewModel.setMidiInputMonitor(d, on: !on)
            tick()
        } label: {
            Image(systemName: on ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.system(size: 11))
                .frame(width: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.accentColor : Color.secondary)
        .opacity(hasInstrument ? 1 : 0.4)
        .disabled(!hasInstrument)
        .help(hasInstrument ? L("inputs.midiMonitor.help") : L("inputs.midiMonitor.none.help"))
    }

    /// A chain whose device is not here: greyed, the instrument kept, nothing to drag or hear.
    private func dormantRow(key: String, chain: MidiInputChain) -> some View {
        HStack(spacing: InputRowStyle.controlSpacing) {
            Image(systemName: ObjectKindIcon.recordMidiInput)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: InputRowStyle.numberWidth, alignment: .trailing)
            Text(verbatim: viewModel.midiInputName(chain.input))
                .font(InputRowStyle.nameFont)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: chain.instrument?.name ?? "")
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .inputRowChrome(isSelected: false)
        .opacity(0.45)
        .help(L("inputs.dormant.help"))
        .contextMenu {
            if chain.instrument != nil {
                Button(L("inputs.instrument.remove")) { viewModel.removeInputInstrument(chainKey: key) }
            }
            if !chain.plugins.isEmpty {
                Button(L("inputs.fx.removeAll")) { viewModel.clearMidiInputFX(chainKey: key) }
            }
        }
    }

    private func tick() {
        let nowHeard = viewModel.heardMidiDeviceIDs
        if nowHeard != heard { heard = nowHeard }
        let seen = viewModel.midiActivity()
        var next = levels
        for d in rows {
            let raw = Float(seen[d.id] ?? 0) / 127
            next[d.id] = VUBallistics.smoothed(previous: next[d.id] ?? 0, raw: raw)
        }
        // A device that left the list leaves the map.
        for id in next.keys where !rows.contains(where: { $0.id == id }) { next[id] = nil }
        if next != levels { levels = next }
        let listed = Set(rows.map(\.id))
        if !selection.isSubset(of: listed) { selection = selection.intersection(listed) }
    }
}

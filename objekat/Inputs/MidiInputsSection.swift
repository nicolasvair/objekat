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
/// extends a range. No rename in v1 (the device's own name is the name), no listening button: an armed zone is
/// heard through its instrument, the section only SHOWS the activity.
struct MidiInputsSection: View {
    @Bindable var viewModel: EditViewModel
    /// The list this section lives in takes the keyboard when a row is clicked.
    var focusList: () -> Void = {}

    /// Smoothed bar position 0...1 of each device.
    @State private var levels: [String: Float] = [:]
    @State private var poll = Timer.publish(every: 0.07, on: .main, in: .common).autoconnect()

    private var rows: [MidiInputInfo] { viewModel.midiInputs }
    private var selection: Set<String> {
        get { viewModel.selectedMidiInputs }
        nonmutating set { viewModel.selectedMidiInputs = newValue }
    }

    var body: some View {
        Group {
            if !rows.isEmpty {
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
                }
            }
        }
        .onReceive(poll) { _ in tick() }
        .onAppear { viewModel.refreshMidiInputs() }
    }

    private func row(_ d: MidiInputInfo) -> some View {
        let isSelected = selection.contains(d.id)
        return VStack(alignment: .leading, spacing: InputRowStyle.lineSpacing) {
            HStack(spacing: InputRowStyle.controlSpacing) {
                Image(systemName: ObjectKindIcon.recordMidiInput)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: InputRowStyle.numberWidth, alignment: .trailing)
                Text(verbatim: d.id == MidiInputResolver.allInputsID ? L("midi.all_inputs") : d.name)
                    .font(InputRowStyle.nameFont)
                    .lineLimit(1)
                Spacer(minLength: 4)
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

    private func tick() {
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

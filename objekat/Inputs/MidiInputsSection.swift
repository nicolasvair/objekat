import SwiftUI
import Combine

/// The « MIDI inputs » section of the Inputs tab (rec3-midi): ABOVE the card's inputs, in the same RECTANGLES
/// (@see InputStrip) — the keys glyph where the card's have their number, the name with the badges of its effects, the
/// speaker and under them a bar that lights with the velocity of the notes played (the plugin cards' bar, 0...127 linear). A
/// MIDI input needs no sound card: the section is there whether or not the audio inputs are open. "All MIDI Ins" comes first.
///
/// A rectangle is dragged onto the timeline to make a MIDI recording zone, or onto a group to give it this input
/// (the same drop as a card input, @see InputDragSession). Dragging a selection that holds both kinds takes
/// them all: one lane per input, the MIDI ones first. The selection is the model's (`selectedMidiInputs`, the
/// device ids): a click selects the rectangle alone and lets go of the card's selection (and opens its popup), ⌘ adds or
/// removes, ⇧ extends a range. No rename (the device's own name is the name).
///
/// A MIDI input can carry ONE instrument and effects behind it (docs/plan_groupes_midi.md): they live in its popup, the
/// synoptic of its chain, instrument slot first like a MIDI object's. The speaker hears the input through it (greyed while
/// there is no instrument) — and it is the ONLY way to hear it live: arming a recording zone on the input is not
/// listening (the zone's capture track plays nothing), the zone's own instrument plays the takes the zone holds. A chain
/// whose device is absent stays as a greyed rectangle, instrument kept.
///
/// The « Computer Keyboard » rectangle (second, under « All MIDI Ins ») is one like the others, plus its own line of controls
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
        let source = RecordSource.midi(d.ref)
        let hasInstrument = viewModel.midiChainKey(for: d).flatMap { viewModel.inputChains.midi[$0]?.instrument } != nil
        let on = heard.contains(d.id)
        return InputStrip(
            glyph: .keys,
            name: d.displayName,
            badges: viewModel.inputStripBadges(source),
            isSelected: selection.contains(d.id),
            isOpen: viewModel.openInputStrip == source,
            heard: on,
            canListen: hasInstrument,
            listenHelp: hasInstrument ? L("inputs.midiMonitor.help") : L("inputs.midiMonitor.none.help"),
            onListen: {
                _ = viewModel.setMidiInputMonitor(d, on: !on)
                tick()
            },
            gain: { EmptyView() },
            extra: {
                if d.isComputerKeyboard { ComputerKeyboardRowControls(viewModel: viewModel) }
            },
            meter: { VULevelBar(level: Double(levels[d.id] ?? 0), height: 3) }
        )
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
            viewModel.applyInputStripClick(source, shift: flags.contains(.shift), command: flags.contains(.command))
        }
        .popover(isPresented: Binding(
            get: { viewModel.openInputStrip == source },
            set: { if !$0 && viewModel.openInputStrip == source { viewModel.openInputStrip = nil } }
        ), arrowEdge: .trailing) {
            InputStripPopup(viewModel: viewModel, source: source)
        }
        .padding(.horizontal, InputRowStyle.horizontalPadding).padding(.vertical, InputRowStyle.stripSpacing / 2)
    }

    /// A chain whose device is not here: greyed, the instrument kept, nothing to drag or hear.
    private func dormantRow(key: String, chain: MidiInputChain) -> some View {
        DormantInputStrip(glyph: .keys, name: viewModel.midiInputName(chain.input), detail: chain.instrument?.name ?? "")
            .padding(.horizontal, InputRowStyle.horizontalPadding).padding(.vertical, InputRowStyle.stripSpacing / 2)
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

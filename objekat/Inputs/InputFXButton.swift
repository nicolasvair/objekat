import SwiftUI

/// The « FX » button of a card input's row (docs/plan_groupes_midi.md, E10): the effects that colour what is HEARD of the
/// input — a recording is taken from the device, before any of them. A click opens a popover with the SAME signal view as a
/// stem's (`SynopticBoundView` on the chain's host id); the chain is held mounted on the engine for as long as the popover
/// is open, then goes back to being mounted only while the input is heard (@see EditViewModel+InputChains).
struct InputFXButton: View {
    @Bindable var viewModel: EditViewModel
    let ref: InputRef
    @State private var open = false
    @State private var host: UUID? = nil

    /// The cards of the chain (the gain stages included), as `input.list` counts them.
    private var count: Int {
        EditViewModel.flattenLeaves(viewModel.inputChains.audio[ref.key]?.plugins ?? []).count
    }

    var body: some View {
        Button {
            let h = viewModel.ensureAudioInputHost(ref)
            host = h
            viewModel.openInputHost(h)
            open = true
        } label: {
            Text(verbatim: count > 0 ? "FX \(count)" : "FX")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(count > 0 ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(count > 0 ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.5), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help(L("inputs.fx.help"))
        .popover(isPresented: $open, arrowEdge: .trailing) {
            if let host { InputFXPopover(viewModel: viewModel, ref: ref, hostID: host) }
        }
        .onChange(of: open) { _, isOpen in
            if !isOpen, let host { viewModel.closeInputHost(host) }
        }
    }
}

/// The popover's content: the input's name, what the chain is for, and the signal view of its host.
private struct InputFXPopover: View {
    @Bindable var viewModel: EditViewModel
    let ref: InputRef
    let hostID: UUID

    private let popoverWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(viewModel.inputName(ref))
                    .font(.system(.caption, weight: .semibold))
                Spacer(minLength: 12)
                Text(L("inputs.fx.note"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            SynopticBoundView(viewModel: viewModel, objectID: hostID, scrolls: true)
                .frame(width: popoverWidth, height: 360)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: popoverWidth)
    }
}

/// The instrument button of a MIDI input's row: its name (or « Instrument » while it has none). Without an instrument a
/// click opens the instrument picker; with one it opens the instrument's own editor. The right click changes or removes.
struct MidiInstrumentButton: View {
    @Bindable var viewModel: EditViewModel
    let device: MidiInputInfo
    @State private var picking = false
    @State private var search = ""
    @State private var pickHost = UUID()

    private func beginPick() {
        pickHost = viewModel.ensureMidiInputHost(device)
        picking = true
    }

    private var chainKey: String? { viewModel.midiChainKey(for: device) }
    private var instrument: ObjectPlugin? { chainKey.flatMap { viewModel.inputChains.midi[$0]?.instrument } }

    var body: some View {
        Button {
            if let instrument, let host = viewModel.midiInputHostID(device) {
                viewModel.togglePluginEditor(objectID: host, plug: instrument)
            } else {
                beginPick()
            }
        } label: {
            Text(instrument?.name ?? L("inputs.instrument.none"))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(instrument == nil ? Color.secondary : Color.primary)
                .frame(maxWidth: 96)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(instrument == nil ? Color.orange.opacity(0.8) : Color.secondary.opacity(0.5), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help(instrument == nil ? L("inputs.instrument.pick.help") : L("inputs.instrument.help"))
        .contextMenu {
            Button(L(instrument == nil ? "inputs.instrument.pick" : "inputs.instrument.change")) { beginPick() }
            if instrument != nil {
                Button(L("inputs.instrument.remove")) { viewModel.removeInputInstrument(device: device) }
            }
        }
        .sheet(isPresented: $picking) {
            PluginPickerSheet(viewModel: viewModel, objectID: pickHost,
                              instrumentsOnly: true, searchText: $search, dismiss: { picking = false }) { available in
                viewModel.setInputInstrument(device: device, available: available)
            }
        }
    }
}

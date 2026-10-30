import SwiftUI
import Combine

/// The "Inputs" tab of the left panel: the sound card's recording inputs, as the project names them.
///
/// Closed at launch — a button opens them (opening is what makes macOS ask for the microphone and
/// switches AirPods to the call profile, so nothing here does it on its own). Then two sections, « Stereo
/// inputs » ABOVE « Mono inputs » (a pair does not take its monos away; an empty section is not shown),
/// one row per input: its number, an editable name, the monitor button and the listening level, and under
/// them the level meter (one bar for a mono, two thin ones, L and R, for a pair).
///
/// The selection is the lists' own (@see ListClickSelection): a click selects the row alone, ⌘ adds or
/// removes it, ⇧ extends a contiguous range, ⌘A takes every row, ↑ / ↓ move it and ⇧↑ / ⇧↓ extend it — the
/// arrows and ⌘A only while this list holds the keyboard (@see KeyboardClaim, `.inputs`). A click in the
/// void under the rows empties it. The right-click menu works on the selection when the row is part of it,
/// else on the row alone: two NEIGHBOURING monos can be linked as one stereo input, a pair can be removed.
/// The names and the pairs belong to the project and are outside the undo (@see EditViewModel+Record);
/// whether an input is being heard belongs to the engine and is not saved.
///
/// Everything it shows is read from the model or from the engine on a 0.07 s poll, the stem strips'
/// cadence and ballistics (@see VUBallistics): this view stores no truth of its own. The meters are the
/// plugin cards' (@see VULevelBar, on the -60...+6 dBFS `VUScale`), fed with the PER-CHANNEL peaks of the
/// card.
struct InputsPanelView: View {
    @Bindable var viewModel: EditViewModel

    @State private var open = false
    /// Smoothed bar position 0...1 (`VUScale`, -60...+6 dBFS) of each CARD channel.
    @State private var levels: [Float] = []
    @State private var monitored: Set<InputRef> = []
    /// The selected rows live in the model (@see EditViewModel.selectedRecordInputs): ⌘R and the
    /// `input.selection` command read the same set the hand sees.
    private var selection: Set<InputRef> {
        get { viewModel.selectedRecordInputs }
        nonmutating set { viewModel.selectedRecordInputs = newValue }
    }
    @State private var failure: String? = nil
    @FocusState private var listFocused: Bool
    @State private var poll = Timer.publish(every: 0.07, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if open {
                list
            } else {
                enableBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(poll) { _ in tick() }
        .onAppear {
            tick()
            // ⌘A while this list holds the keyboard (@see KeyboardClaim.performSelectAll).
            KeyboardClaim.shared.inputsSelectAll = { selection = ListClickSelection.all(ordered: orderedRows) }
        }
        .onDisappear {
            KeyboardClaim.shared.release(.inputs)
            KeyboardClaim.shared.inputsSelectAll = nil
        }
    }

    // MARK: Closed

    private var enableBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if AudioDeviceStatus.shared.snapshot.inputsSeparate {
                // AirPods and the like: the microphone is another device, which the engine refuses.
                Text(L("inputs.separateDevice"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(L("inputs.enable")) {
                    failure = viewModel.enableRecordInputs()
                    tick()
                }
                .help(L("inputs.enable.help"))
            }
            if let failure {
                Text(L("inputs.openFailed", failure))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: Open

    /// The rows as shown, top to bottom: every pair, then every mono. What ⇧ ranges and the arrows walk.
    private var orderedRows: [InputRef] { stereoRows + monoRows }
    private var monoRows: [InputRef] { viewModel.visibleRecordInputs.filter { !$0.isStereo } }
    private var stereoRows: [InputRef] { viewModel.visibleRecordInputs.filter(\.isStereo) }

    private var list: some View {
        let monos = monoRows, pairs = stereoRows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !pairs.isEmpty {
                        sectionHeader(L("inputs.section.stereo"))
                        ForEach(pairs, id: \.self) { ref in row(ref) }
                    }
                    if !monos.isEmpty {
                        sectionHeader(L("inputs.section.mono"))
                        ForEach(monos, id: \.self) { ref in row(ref) }
                    }
                    // The void under the rows: a click there empties the selection and ends a rename
                    // (committing it), like a click on the canvas. Not an ancestor gesture, which would
                    // also fire over the field.
                    Color.clear.frame(height: 60).contentShape(Rectangle())
                        .onTapGesture { clickVoid() }
                }
            }
            // The void below the 60 pt spacer, when the rows do not fill the panel: behind the rows, so
            // a row or its field still gets its own click first.
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { clickVoid() })
            .focusable()
            .focused($listFocused)
            // The timeline's key monitor must let ↑ / ↓ through while this list holds them, and take
            // them back the moment it does not (@see `KeyboardClaim`).
            .onChange(of: listFocused) { _, f in
                if f { KeyboardClaim.shared.claim(.inputs) } else { KeyboardClaim.shared.release(.inputs) }
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                step(press.key == .upArrow ? -1 : 1, extend: press.modifiers.contains(.shift), proxy: proxy)
                return .handled
            }
        }
    }

    /// A section's title: the zones' (the synoptic's) small grey semibold.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    // MARK: Selecting

    /// A click on a row (or on its name with ⌘ / ⇧): the modifiers read at the click.
    private func select(_ ref: InputRef) {
        let flags = NSEvent.modifierFlags
        selection = ListClickSelection.apply(current: selection, clicked: ref, ordered: orderedRows,
                                             shift: flags.contains(.shift), command: flags.contains(.command))
    }

    private func clickVoid() {
        viewModel.renamingInput = nil
        selection = []
        listFocused = true
    }

    /// ↑ / ↓ (`delta` -1 / +1), ⇧ extending: the selection moves and the list follows it.
    private func step(_ delta: Int, extend: Bool, proxy: ScrollViewProxy) {
        let ordered = orderedRows
        let next = ListClickSelection.move(current: selection, delta: delta, ordered: ordered, extend: extend)
        if next != selection { selection = next }
        if let i = ListClickSelection.edge(of: next, delta: delta, ordered: ordered) {
            proxy.scrollTo(ordered[i])
        }
    }

    private func row(_ ref: InputRef) -> some View {
        let isSelected = selection.contains(ref)
        let heard = monitored.contains(ref)
        return VStack(spacing: 2) {
            HStack(spacing: 8) {
                Text(verbatim: ref.key)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .trailing)
                if viewModel.renamingInput == ref {
                    // Leaving commits what was typed, Esc cancels (@see MarkerRenameField).
                    MarkerRenameField(initial: viewModel.inputName(ref),
                                      font: .system(.caption, weight: .semibold),
                                      commitsOnFocusLoss: true) { value in
                        if let value { viewModel.renameInput(ref, to: value) }
                        if viewModel.renamingInput == ref { viewModel.renamingInput = nil }
                    }
                } else {
                    Text(viewModel.inputName(ref))
                        .font(.system(.caption, weight: .semibold))
                        .lineLimit(1)
                        .onTapGesture {
                            // ⌘ / ⇧ on the name select (a range is aimed at the rows, and the name is
                            // most of the row); a bare click renames.
                            let flags = NSEvent.modifierFlags
                            if flags.contains(.command) || flags.contains(.shift) {
                                listFocused = true
                                viewModel.renamingInput = nil
                                select(ref)
                            } else {
                                viewModel.renamingInput = ref
                            }
                        }
                        .help(L("inputs.rename.help"))
                }
                Spacer(minLength: 4)
                Button {
                    _ = viewModel.setInputMonitor(ref, on: !heard)
                    tick()
                } label: {
                    Image(systemName: heard ? "speaker.wave.2.fill" : "speaker.slash")
                        .font(.system(size: 11))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(heard ? Color.accentColor : Color.secondary)
                .help(L("inputs.monitor.help"))
                monitorGainBox(ref, heard: heard)
            }
            vuBars(ref)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        // The row is dragged onto the timeline to make a recording zone, or onto a group to give it
        // this input (@see RecordZonePlanner, InputDragSession).
        .onDrag { InputDragSession.shared.begin(InputDragSession.carried(ref, selection: selection)) }
        .onTapGesture {
            listFocused = true
            viewModel.renamingInput = nil
            select(ref)
        }
        .contextMenu { contextMenu(for: ref) }
        .id(ref)
    }

    /// The input's level, across the whole row, under the controls: one bar for a mono, two thin ones (left
    /// over right) for a pair — the plugin cards' bar, on the same scale (red past 0 dBFS).
    @ViewBuilder
    private func vuBars(_ ref: InputRef) -> some View {
        Group {
            if ref.isStereo {
                VStack(spacing: 1) {
                    VULevelBar(level: Double(channelLevel(ref.first)))
                    VULevelBar(level: Double(channelLevel(ref.first + 1)))
                }
            } else {
                VULevelBar(level: Double(channelLevel(ref.first)), height: 3)
            }
        }
        .frame(height: 5)
    }

    /// The most a DRAG may raise the listening level above where it started (a typed value is only held
    /// to the box's range).
    private static let monitorRiseLimit: Double = 6
    private static let gainRange = Double(GainStageValues.gainRange.lowerBound)...Double(GainStageValues.gainRange.upperBound)

    /// The listening level of the input, in dB: the synoptic's gain box (drag, ⇧ fine, arrows, typing,
    /// double-click = 0 dB). Hearing only — it does not touch what is recorded. Greyed and inert while the
    /// input is not heard.
    private func monitorGainBox(_ ref: InputRef, heard: Bool) -> some View {
        DragValueBox(value: viewModel.inputMonitorGain(ref),
                     format: { $0 == 0 ? "0 dB" : String(format: "%+.0f dB", $0) },
                     range: Self.gainRange,
                     pointsPerStep: 6, snap: true, width: 44,
                     keyStep: 1, fineKeyStep: FineAdjust.dbFineStep, coarseKeyStep: FineAdjust.dbBigStep,
                     dragRiseLimit: Self.monitorRiseLimit,
                     help: L("inputs.monitorGain.help"),
                     onChange: { _ = viewModel.setInputMonitorGain(ref, db: $0); tick() },
                     onReset: { _ = viewModel.setInputMonitorGain(ref, db: 0); tick() })
            .opacity(heard ? 1 : 0.4)
            .disabled(!heard)
    }

    /// The right-click menu: it acts on the selection when the row belongs to it, else on the row alone.
    @ViewBuilder
    private func contextMenu(for ref: InputRef) -> some View {
        let target = selection.contains(ref) ? Array(selection) : [ref]
        if let first = InputPairing.pairableFirst(target), !viewModel.recordInputs.pairs.contains(first) {
            Button(L("inputs.pair")) {
                viewModel.pairInputs(first: first)
                selection = []
            }
            .disabled(viewModel.inputPairsLocked)   // the pairs are fixed while a recording runs
        }
        let pairs = target.filter(\.isStereo)
        if !pairs.isEmpty {
            Button(L("inputs.unpair")) {
                for pair in pairs { viewModel.unpairInputs(first: pair.first) }
                selection.subtract(pairs)
            }
            .disabled(viewModel.inputPairsLocked)
        }
    }

    // MARK: Reading the engine

    private func channelLevel(_ channel: Int) -> Float {
        channel < levels.count ? levels[channel] : 0
    }

    private func tick() {
        guard let engine = viewModel.engine, engine.audioInputsOpen() else {
            if open { open = false }
            if !levels.isEmpty { levels = [] }
            if !monitored.isEmpty { monitored = [] }
            if !selection.isEmpty { selection = [] }
            return
        }
        if !open { open = true; failure = nil }
        let peaks = engine.audioInputPeaksDb()
        var next = levels
        if next.count != peaks.count { next = Array(repeating: 0, count: peaks.count) }
        for (i, db) in peaks.enumerated() {
            let raw = Float(VUScale.fraction(db.doubleValue))
            next[i] = VUBallistics.smoothed(previous: next[i], raw: raw)
        }
        levels = next
        let heard = Set(viewModel.monitoredInputs)
        if heard != monitored { monitored = heard }
        // A selection that no longer lists (a pairing swallowed it) is dropped.
        let listed = Set(viewModel.visibleRecordInputs)
        if !selection.isSubset(of: listed) { selection = selection.intersection(listed) }
    }
}

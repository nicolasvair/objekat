import SwiftUI
import Combine

/// The "Inputs" tab of the left panel: the sound card's recording inputs, as the project names them.
///
/// Closed at launch — a button opens them (opening is what makes macOS ask for the microphone and
/// switches AirPods to the call profile, so nothing here does it on its own). Then one row per input:
/// its number, a level dot, an editable name, the listening level and a monitor button. The pairs come first, then every
/// mono (a pair does not take its monos away). The right-click menu works on the selection (⌘ or ⇧ click
/// to extend it) when the row is part of it, else on the row alone: two NEIGHBOURING monos can be linked
/// as one stereo input, a pair can be removed. The names and the pairs belong to the project and are
/// outside the undo (@see EditViewModel+Record);
/// whether an input is being heard belongs to the engine and is not saved.
///
/// Everything it shows is read from the model or from the engine on a 0.07 s poll, the stem strips'
/// cadence and ballistics (@see StemVuDot, VUBallistics): this view stores no truth of its own.
struct InputsPanelView: View {
    @Bindable var viewModel: EditViewModel

    @State private var open = false
    /// Smoothed level 0...1 (over -60...0 dBFS) of each CARD channel.
    @State private var levels: [Float] = []
    @State private var monitored: Set<InputRef> = []
    @State private var selection: Set<InputRef> = []
    @State private var failure: String? = nil
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
        .onAppear { tick() }
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

    private var list: some View {
        let rows = viewModel.visibleRecordInputs
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.self) { ref in row(ref) }
                    // The void under the rows: a click there ends a rename (committing it), like a click
                    // on the canvas. Not an ancestor gesture, which would also fire over the field.
                    Color.clear.frame(height: 60).contentShape(Rectangle())
                        .onTapGesture { viewModel.renamingInput = nil }
                }
            }
        }
    }

    private func row(_ ref: InputRef) -> some View {
        let isSelected = selection.contains(ref)
        return HStack(spacing: 8) {
            Text(verbatim: ref.key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 30, alignment: .trailing)
            StemVuDot(level: level(of: ref))
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
                    .onTapGesture { viewModel.renamingInput = ref }
                    .help(L("inputs.rename.help"))
            }
            Spacer(minLength: 4)
            monitorGainBox(ref, heard: monitored.contains(ref))
            Button {
                _ = viewModel.setInputMonitor(ref, on: !monitored.contains(ref))
                tick()
            } label: {
                Image(systemName: monitored.contains(ref) ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 11))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(monitored.contains(ref) ? Color.accentColor : Color.secondary)
            .help(L("inputs.monitor.help"))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        // The row is dragged onto the timeline to make a recording zone, or onto a group to give it
        // this input (@see RecordZonePlanner, InputDragSession).
        .onDrag { InputDragSession.shared.begin(InputDragSession.carried(ref, selection: selection)) }
        .onTapGesture {
            viewModel.renamingInput = nil
            let extend = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
            if extend {
                if isSelected { selection.remove(ref) } else { selection.insert(ref) }
            } else {
                selection = [ref]
            }
        }
        .contextMenu { contextMenu(for: ref) }
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
        }
        let pairs = target.filter(\.isStereo)
        if !pairs.isEmpty {
            Button(L("inputs.unpair")) {
                for pair in pairs { viewModel.unpairInputs(first: pair.first) }
                selection.subtract(pairs)
            }
        }
    }

    // MARK: Reading the engine

    private func level(of ref: InputRef) -> Float {
        ref.channels.map { $0 < levels.count ? levels[$0] : 0 }.max() ?? 0
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
            let raw = Float(min(1, max(0, (db.doubleValue + 60) / 60)))
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

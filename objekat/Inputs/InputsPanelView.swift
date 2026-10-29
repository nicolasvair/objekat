import SwiftUI
import Combine

/// The "Inputs" tab of the left panel: the sound card's recording inputs, as the project names them.
///
/// Closed at launch — a button opens them (opening is what makes macOS ask for the microphone and
/// switches AirPods to the call profile, so nothing here does it on its own). Then one row per input:
/// its number, a level dot, an editable name and a monitor button. Two NEIGHBOURING monos selected
/// (⌘ or ⇧ click for the second) can be read as one stereo input; a stereo row has "Unlink". The names
/// and the pairs belong to the project and are outside the undo (@see EditViewModel+Record);
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
    @State private var renaming: InputRef? = nil
    @State private var editText = ""
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
            Button(L("inputs.enable")) {
                failure = viewModel.enableRecordInputs()
                tick()
            }
            .help(L("inputs.enable.help"))
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
            if let first = InputPairing.pairableFirst(Array(selection)) {
                HStack {
                    Button(L("inputs.pair")) {
                        viewModel.pairInputs(first: first)
                        selection = []
                    }
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.self) { ref in row(ref) }
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
            if renaming == ref {
                TextField(noLabel, text: $editText)
                    .font(.system(.caption, weight: .semibold))
                    .textFieldStyle(.plain)
                    .onSubmit { viewModel.renameInput(ref, to: editText); renaming = nil }
                    .onExitCommand { renaming = nil }
            } else {
                Text(viewModel.inputName(ref))
                    .font(.system(.caption, weight: .semibold))
                    .lineLimit(1)
                    .onTapGesture { editText = viewModel.inputName(ref); renaming = ref }
                    .help(L("inputs.rename.help"))
            }
            Spacer(minLength: 4)
            if ref.isStereo {
                Button(L("inputs.unpair")) {
                    viewModel.unpairInputs(first: ref.first)
                    selection.remove(ref)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
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
        .onTapGesture {
            renaming = nil
            let extend = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
            if extend {
                if isSelected { selection.remove(ref) } else { selection.insert(ref) }
            } else {
                selection = [ref]
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
